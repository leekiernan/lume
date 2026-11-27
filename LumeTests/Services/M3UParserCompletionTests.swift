//
//  M3UParserCompletionTests.swift
//  LumeTests
//
//  The chunk reader's lifecycle: only a read that reaches end of file
//  completes. A read error, cancellation or an over-long line ends in its own
//  terminal phase, and `parseStreaming` throws for each, so a partly read
//  playlist can never pass for a complete one (and reach the prune).
//

import Foundation
@testable import Lume
import Testing

struct M3UParserCompletionTests {
    private typealias Reader = M3UChunkReader

    private static let entry = "#EXTINF:-1 group-title=\"News\",One\nhttp://example.com/1.ts\n"

    private static func chunk(_ text: String) -> Reader.Input {
        .chunk(Data(text.utf8))
    }

    private static func entries(_ batches: [M3UParser.ReadyBatch]) -> [M3UEntry] {
        batches.flatMap(\.entries)
    }

    private static func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m3u")
        try data.write(to: url)
        return url
    }

    // MARK: Reader transitions

    @Test func `end of file completes and delivers the trailing batch`() {
        var reader = Reader(batchSize: 10)
        // A line split across two chunks.
        #expect(reader.step(Self.chunk("#EXTM3U\n#EXTINF:-1,One\nhttp://exa"), onHeader: nil).isEmpty)
        #expect(reader.step(Self.chunk("mple.com/1.ts\n"), onHeader: nil).isEmpty)
        let final = reader.step(.endOfFile, onHeader: nil)

        #expect(Self.entries(final).map(\.url) == ["http://example.com/1.ts"])
        #expect(reader.totalCount == 1)
        guard case .completed = reader.phase else {
            Issue.record("expected completed, got \(reader.phase)")
            return
        }
    }

    @Test func `a final line without a newline still completes`() {
        var reader = Reader(batchSize: 10)
        _ = reader.step(Self.chunk("#EXTINF:-1,One\nhttp://example.com/1.ts"), onHeader: nil)
        let final = reader.step(.endOfFile, onHeader: nil)
        #expect(Self.entries(final).count == 1)
        #expect(!reader.phase.isReading)
    }

    @Test func `a read error ends in failure, not completion`() {
        var reader = Reader(batchSize: 10)
        _ = reader.step(Self.chunk(Self.entry), onHeader: nil)
        let ready = reader.step(.readFailed(CocoaError(.fileReadUnknown)), onHeader: nil)

        #expect(ready.isEmpty)
        guard case let .failed(error) = reader.phase else {
            Issue.record("expected failed, got \(reader.phase)")
            return
        }
        #expect((error as? CocoaError)?.code == .fileReadUnknown)
    }

    @Test func `cancellation ends in its own phase and drops the pending batch`() {
        var reader = Reader(batchSize: 10)
        _ = reader.step(Self.chunk(Self.entry), onHeader: nil)
        let ready = reader.step(.cancelled, onHeader: nil)

        #expect(ready.isEmpty)
        guard case .cancelled = reader.phase else {
            Issue.record("expected cancelled, got \(reader.phase)")
            return
        }
    }

    @Test func `a partial line past the limit is rejected before it grows further`() {
        var reader = Reader(batchSize: 10)
        let long = String(repeating: "a", count: M3UParser.maximumLineBytes + 1)
        _ = reader.step(Self.chunk(long), onHeader: nil)
        guard case let .failed(error) = reader.phase, case .lineTooLong = error as? M3UParseError else {
            Issue.record("expected lineTooLong, got \(reader.phase)")
            return
        }
    }

    @Test func `a complete line past the limit is rejected`() {
        var reader = Reader(batchSize: 10)
        let long = String(repeating: "a", count: M3UParser.maximumLineBytes + 1)
        _ = reader.step(Self.chunk(long + "\nhttp://example.com/1.ts\n"), onHeader: nil)
        guard case let .failed(error) = reader.phase, case .lineTooLong = error as? M3UParseError else {
            Issue.record("expected lineTooLong, got \(reader.phase)")
            return
        }
    }

    @Test func `a line at the limit is accepted`() {
        var reader = Reader(batchSize: 10)
        let name = String(repeating: "a", count: M3UParser.maximumLineBytes - "#EXTINF:-1,".utf8.count)
        _ = reader.step(Self.chunk("#EXTINF:-1,\(name)\nhttp://example.com/1.ts\n"), onHeader: nil)
        let final = reader.step(.endOfFile, onHeader: nil)
        #expect(Self.entries(final).count == 1)
    }

    // MARK: File input

    @Test func `a failed read is reported as the error, not end of file`() throws {
        // A descriptor opened write-only fails every read (EBADF): a real read
        // error without closing a descriptor another parallel test could be
        // handed in the meantime.
        let url = try Self.writeTemp(Data(Self.entry.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_WRONLY)
        try #require(descriptor >= 0)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        guard case .readFailed = M3UParser.nextInput(from: handle) else {
            Issue.record("a failed read must not read as a chunk or end of file")
            return
        }
    }

    @Test func `parseStreaming throws when its task is already cancelled`() async throws {
        let url = try Self.writeTemp(Data((Self.entry + Self.entry).utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await M3UParser.parseStreaming(fileURL: url) { _, _ in }
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func `parseStreaming throws on an over-long line instead of returning a prefix`() async throws {
        var data = Data((Self.entry).utf8)
        data.append(Data(repeating: UInt8(ascii: "a"), count: M3UParser.maximumLineBytes + 1))
        let url = try Self.writeTemp(data)
        defer { try? FileManager.default.removeItem(at: url) }

        var delivered = 0
        await #expect(throws: M3UParseError.self) {
            try await M3UParser.parseStreaming(fileURL: url) { batch, _ in delivered += batch.count }
        }
        #expect(delivered == 0)
    }

    @Test func `a complete multi-chunk file still returns its full count`() async throws {
        // Well past one 512 KB chunk.
        let count = 12000
        var text = "#EXTM3U\n"
        for index in 0 ..< count {
            text += "#EXTINF:-1 group-title=\"G\",Channel \(index)\nhttp://example.com/\(index).ts\n"
        }
        let url = try Self.writeTemp(Data(text.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        var delivered = 0
        let returned = try await M3UParser.parseStreaming(fileURL: url, batchSize: 2000) { batch, _ in
            delivered += batch.count
        }
        #expect(returned == count)
        #expect(delivered == count)
    }
}
