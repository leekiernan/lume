//
//  NetworkReadBenchmarks.swift
//  LumePerformanceTests
//
//  Three ways to read an HTTP body against a size limit, over loopback:
//  `data(for:)` then check (today: the whole body is collected first),
//  `bytes(for:)` checked per byte, and `BoundedResponse` (a per-task data
//  delegate checked per chunk). Each is measured for clock, CPU and peak
//  memory on the accepted case — five 8 MB reads, a metadata batch run — and
//  on an undeclared 64 MB body against an 8 MB limit, where peak memory is
//  the point. Peak memory is the process's high-water mark, so compare it
//  only between runs of one test each (`Scripts/run-performance-tests.sh
//  NetworkReadBenchmarks/<test>`). Connection reuse is checked separately: a
//  bounded read must keep the session's keep-alive connection.
//

import Foundation
@testable import Lume
import Network
import XCTest

final class NetworkReadBenchmarks: XCTestCase {
    private static let limit = 8 * 1024 * 1024
    private var server: KeepAliveServer?
    private var base: URL!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        // `LUME_PERF_HTTP` (via `TEST_RUNNER_LUME_PERF_HTTP`) points at an
        // out-of-process server with the same paths, so peak memory is the
        // reader's alone rather than the reader's plus the server's.
        if let external = ProcessInfo.processInfo.environment["LUME_PERF_HTTP"].flatMap(URL.init(string:)) {
            base = external
        } else {
            let server = try KeepAliveServer(bodies: [
                "/accepted": (Data(repeating: 0x61, count: Self.limit), declared: true),
                "/oversized": (Data(repeating: 0x61, count: 64 * 1024 * 1024), declared: false)
            ])
            self.server = server
            base = try await server.start()
        }
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        server?.stop()
        try await super.tearDown()
    }

    private enum Reader {
        case collectThenCheck, bytesPerByte, bounded
    }

    private func read(_ path: String, with reader: Reader) async -> Int {
        let request = URLRequest(url: base.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        let limit = Self.limit
        switch reader {
        case .collectThenCheck:
            guard let (data, _) = try? await session.data(for: request), data.count <= limit else { return -1 }
            return data.count
        case .bytesPerByte:
            guard let (bytes, _) = try? await session.bytes(for: request) else { return -1 }
            var data = Data()
            do {
                for try await byte in bytes {
                    guard data.count < limit else {
                        bytes.task.cancel()
                        return -1
                    }
                    data.append(byte)
                }
            } catch { return -1 }
            return data.count
        case .bounded:
            guard let (data, _) = try? await BoundedResponse.data(for: request, session: session, limit: limit) else { return -1 }
            return data.count
        }
    }

    private func measureReads(_ path: String, times: Int, with reader: Reader, expecting: Int) {
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            let done = expectation(description: "reads")
            Task.detached { [self] in
                for _ in 0 ..< times {
                    let count = await read(path, with: reader)
                    XCTAssertEqual(count, expecting)
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 120)
        }
    }

    // MARK: - Accepted: five 8 MB bodies

    func testAcceptedCollectThenCheck() {
        measureReads("/accepted", times: 5, with: .collectThenCheck, expecting: Self.limit)
    }

    func testAcceptedBytesPerByte() {
        measureReads("/accepted", times: 5, with: .bytesPerByte, expecting: Self.limit)
    }

    func testAcceptedBounded() {
        measureReads("/accepted", times: 5, with: .bounded, expecting: Self.limit)
    }

    // MARK: - Oversized: an undeclared 64 MB body, 8 MB limit

    func testOversizedCollectThenCheck() {
        measureReads("/oversized", times: 1, with: .collectThenCheck, expecting: -1)
    }

    func testOversizedBytesPerByte() {
        measureReads("/oversized", times: 1, with: .bytesPerByte, expecting: -1)
    }

    func testOversizedBounded() {
        measureReads("/oversized", times: 1, with: .bounded, expecting: -1)
    }

    // MARK: - Connection reuse

    /// The second of two reads on one session reuses the first's connection.
    func testBoundedReadKeepsTheConnection() async throws {
        let metrics = MetricsRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: metrics, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: base.appending(path: "/accepted"), cachePolicy: .reloadIgnoringLocalCacheData)
        for _ in 0 ..< 2 {
            _ = try await BoundedResponse.data(for: request, session: session, limit: Self.limit)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(metrics.reused, [false, true])
    }
}

/// Collects each task's `isReusedConnection`, reaching the session delegate
/// because `BoundedResponse`'s task delegate doesn't implement metrics.
private final class MetricsRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    var reused: [Bool] {
        lock.withLock { values }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let reused = metrics.transactionMetrics.last?.isReusedConnection ?? false
        lock.withLock { values.append(reused) }
    }
}

/// Loopback HTTP/1.1 that serves fixed bodies by path. A declared body keeps
/// the connection alive for the next request; an undeclared one is ended by
/// closing it.
private final class KeepAliveServer: @unchecked Sendable {
    private let listener: NWListener
    private let bodies: [String: (Data, declared: Bool)]

    init(bodies: [String: (Data, declared: Bool)]) throws {
        self.bodies = bodies
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.serve(connection, buffered: Data())
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            let bytes = buffered + (data ?? Data())
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { serve(connection, buffered: bytes) }
                return
            }
            let head = String(bytes: bytes[..<end.lowerBound], encoding: .utf8) ?? ""
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let remainder = Data(bytes[end.upperBound...])
            guard let (body, declared) = bodies[path] else {
                send(connection, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", body: Data(), keepAlive: true, remainder: remainder)
                return
            }
            let length = declared ? "Content-Length: \(body.count)\r\n" : "Connection: close\r\n"
            send(connection, head: "HTTP/1.1 200 OK\r\n\(length)\r\n", body: body, keepAlive: declared, remainder: remainder)
        }
    }

    private func send(_ connection: NWConnection, head: String, body: Data, keepAlive: Bool, remainder: Data) {
        // Head and body sent apart: joining them would copy the body, and
        // the server shares the process whose peak memory is measured.
        connection.send(content: Data(head.utf8), completion: .idempotent)
        connection.send(content: body, completion: .contentProcessed { [weak self] _ in
            if keepAlive { self?.serve(connection, buffered: remainder) } else { connection.cancel() }
        })
    }
}
