//
//  M3UParser.swift
//  Lume
//
//  Streaming parser for m3u / m3u8 playlists (the "extended m3u" IPTV dialect:
//  #EXTINF lines with tvg-* attributes followed by a stream URL).
//
//  Like XMLTVParser, it never holds the whole file in memory: the file is read
//  in fixed-size chunks, split into lines, and parsed entries are handed to the
//  caller in batches. Chunking alone is not enough — the per-line temporaries
//  are autoreleased, and the sync actor's import job offers no suspension point
//  for the enclosing pool to drain at, so the chunk loop drains its own pool per
//  iteration. That is what makes a multi-hundred-megabyte provider export parse
//  with flat memory.
//

import Foundation

// MARK: - Parsed values

/// The `#EXTM3U` header line's attributes.
nonisolated struct M3UHeader {
    /// XMLTV guide URL from `url-tvg` / `x-tvg-url`, when the playlist carries one.
    var epgURL: String?
}

/// One playlist entry: an `#EXTINF` line plus the stream URL that follows it.
nonisolated struct M3UEntry {
    var name: String
    var url: String
    var tvgId: String?
    var logo: String?
    var group: String?
    /// The provider's explicit `type="…"` attribute (e.g. `video` for VOD),
    /// when present. Some providers serve live and on-demand through identical
    /// URLs and only this attribute distinguishes them.
    var type: String?
}

/// Why a playlist file was rejected part-way through. A read error is rethrown
/// as itself; this covers what the parser rejects on its own account.
nonisolated enum M3UParseError: LocalizedError {
    /// A line ran past `M3UParser.maximumLineBytes` without a newline.
    case lineTooLong(limit: Int)

    /// The system's own wording for a malformed file, so no new string needs
    /// translating; the case itself is what logs and tests distinguish.
    var errorDescription: String? {
        CocoaError(.fileReadCorruptFile).localizedDescription
    }
}

// MARK: - Parser

nonisolated enum M3UParser {
    /// Bytes read from disk per chunk. Large enough to amortize I/O, small
    /// enough to keep memory flat.
    private static let chunkSize = 512 * 1024

    /// Reads just the `#EXTM3U` header, without parsing the entries behind it.
    ///
    /// The header is the file's first non-empty line, so one chunk always
    /// carries it. This exists for the skip-if-unchanged path: a playlist whose
    /// bytes are unchanged still has to surrender its `url-tvg` to a user who
    /// has since cleared their guide URL, and re-parsing half a gigabyte of
    /// entries to reach line one would give the whole skip back.
    ///
    /// Returns `nil` for a file that is unreadable or carries no header line.
    static func readHeader(fileURL: URL) -> M3UHeader? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil else { return nil }

        for lineData in chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let raw = String(bytes: lineData, encoding: .utf8)
                ?? String(bytes: lineData, encoding: .isoLatin1)
            guard let line = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }
            guard line.hasPrefix("#EXTM3U") else { return nil }
            return parseHeader(line)
        }
        return nil
    }

    /// Parses an m3u file from disk, calling `onBatch` for every `batchSize`
    /// entries (and once more with the remainder). Returns the total entry count.
    ///
    /// `onHeader` fires at most once, as soon as the `#EXTM3U` line is seen —
    /// before any batch — so callers can pick up the embedded EPG URL.
    ///
    /// `onBatch`'s second argument is how many bytes of the file have been
    /// consumed at that point. A streaming parse doesn't know the entry count
    /// until it ends, so bytes-over-file-size is the only progress fraction a
    /// caller can report honestly while the import is running. It may suspend:
    /// the m3u import's producer hands each batch to a bounded channel and parks
    /// there whenever the writer falls behind.
    ///
    /// The hand-off happens *outside* the per-chunk `autoreleasepool` — an
    /// `await` may not cross one — so a chunk's completed batches are collected
    /// first and delivered after the pool drains. A 512 KB chunk holds well
    /// under two provider-shaped batches, so that collection is bounded. The
    /// pool itself is per chunk, not per file: `subdata`, `String(bytes:)` and
    /// `trimmingCharacters` autorelease once per line, and without it a 520 MB
    /// playlist peaks at ~502 MB resident.
    ///
    /// Only a read that reaches end of file returns. A read error is rethrown
    /// as itself, a cancelled task throws `CancellationError`, and a line
    /// longer than `maximumLineBytes` throws `M3UParseError.lineTooLong` — so a
    /// partly read file can never pass for a complete one. Batches already
    /// delivered stay delivered; the caller must treat anything but a return as
    /// "the file was not fully read" (the import neither prunes nor records a
    /// digest after a throw).
    @discardableResult
    static func parseStreaming(
        fileURL: URL,
        batchSize: Int = 2000,
        onHeader: ((M3UHeader) -> Void)? = nil,
        onBatch: ([M3UEntry], _ bytesConsumed: Int) async throws -> Void
    ) async throws -> Int {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var reader = M3UChunkReader(batchSize: batchSize)
        while reader.phase.isReading {
            let input: M3UChunkReader.Input = Task.isCancelled ? .cancelled : nextInput(from: handle)
            let ready = autoreleasepool { reader.step(input, onHeader: onHeader) }
            for batch in ready {
                try await onBatch(batch.entries, batch.bytesConsumed)
            }
        }
        switch reader.phase {
        case .completed:
            return reader.totalCount
        case let .failed(error):
            throw error
        case .cancelled:
            throw CancellationError()
        case .reading:
            preconditionFailure("the read loop only exits on a terminal phase")
        }
    }

    /// The longest line the reader will buffer. Real `#EXTINF` and URL lines
    /// run to a few KB; a file with no newline for a megabyte is not a playlist,
    /// and without a cap the carry buffer would grow with it. Memory is bounded
    /// by this plus one chunk.
    static let maximumLineBytes = 1024 * 1024

    /// The reader's next input from the file: a chunk, end of file, or the
    /// read error itself — never a failure disguised as end of file.
    static func nextInput(from handle: FileHandle) -> M3UChunkReader.Input {
        do {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return .endOfFile }
            return .chunk(chunk)
        } catch {
            return .readFailed(error)
        }
    }

    // MARK: - Chunk loop

    /// One completed batch on its way out of `M3UChunkReader`.
    typealias ReadyBatch = (entries: [M3UEntry], bytesConsumed: Int)

    // MARK: - Line state machine

    /// Carries the pending `#EXTINF` metadata between lines until the stream
    /// URL arrives.
    fileprivate nonisolated struct ParseState {
        var pendingInfo: ExtInf?
        /// Group from a standalone `#EXTGRP:` directive (some providers emit it
        /// instead of, or in addition to, `group-title`).
        var pendingGroup: String?
        var headerDelivered = false

        mutating func consume(line: String, onHeader: ((M3UHeader) -> Void)?) -> M3UEntry? {
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    pendingInfo = M3UParser.parseExtInf(line)
                } else if line.hasPrefix("#EXTGRP:") {
                    pendingGroup = String(line.dropFirst("#EXTGRP:".count))
                        .trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("#EXTM3U"), !headerDelivered {
                    headerDelivered = true
                    onHeader?(M3UParser.parseHeader(line))
                }
                // Anything else (#EXTVLCOPT, #KODIPROP, comments…) is skipped.
                return nil
            }

            // A non-comment line is the stream URL for the pending entry.
            defer {
                pendingInfo = nil
                pendingGroup = nil
            }

            guard let info = pendingInfo else {
                // Plain (non-extended) m3u: a bare URL with no metadata.
                guard looksLikeURL(line) else { return nil }
                let fallbackName = URL(string: line)?.deletingPathExtension().lastPathComponent ?? line
                return M3UEntry(name: fallbackName, url: line, tvgId: nil, logo: nil, group: pendingGroup, type: nil)
            }

            let name = info.name.isEmpty ? (info.tvgName ?? line) : info.name
            return M3UEntry(
                name: name,
                url: line,
                tvgId: info.tvgId,
                logo: info.logo,
                group: info.group ?? pendingGroup,
                type: info.type
            )
        }

        private func looksLikeURL(_ line: String) -> Bool {
            line.contains("://")
        }
    }

    // MARK: - #EXTINF parsing

    nonisolated struct ExtInf {
        var name: String
        var tvgId: String?
        var tvgName: String?
        var logo: String?
        var group: String?
        var type: String?
    }

    /// Parses `#EXTINF:-1 tvg-id="..." tvg-logo="..." group-title="...",Name`.
    ///
    /// Attribute values may contain commas, so the display name is whatever
    /// follows the first comma *after* the last quoted attribute value.
    static func parseExtInf(_ line: String) -> ExtInf {
        let body = String(line.dropFirst("#EXTINF:".count))

        let attributes = parseAttributes(body)

        // Name: after the first comma past the end of the last quoted value.
        var name = ""
        let searchStart: String.Index = if let lastQuote = body.lastIndex(of: "\"") {
            body.index(after: lastQuote)
        } else {
            body.startIndex
        }
        if let comma = body[searchStart...].firstIndex(of: ",") {
            name = String(body[body.index(after: comma)...])
                .trimmingCharacters(in: .whitespaces)
        }

        return ExtInf(
            name: name,
            tvgId: nonEmpty(attributes["tvg-id"]),
            tvgName: nonEmpty(attributes["tvg-name"]),
            logo: nonEmpty(attributes["tvg-logo"]),
            group: nonEmpty(attributes["group-title"]),
            type: nonEmpty(attributes["type"])
        )
    }

    static func parseHeader(_ line: String) -> M3UHeader {
        let attributes = parseAttributes(line)
        return M3UHeader(epgURL: nonEmpty(attributes["url-tvg"]) ?? nonEmpty(attributes["x-tvg-url"]))
    }

    /// Extracts `key="value"` pairs (the only attribute form the IPTV dialect
    /// uses in practice). A single manual scan — no regex — because this runs
    /// once per line on playlists with hundreds of thousands of lines.
    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex

        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let valueStart = text.index(after: equals)
            guard valueStart < text.endIndex, text[valueStart] == "\"" else {
                index = valueStart
                continue
            }
            // Key: identifier characters immediately before '='.
            var keyStart = equals
            while keyStart > index {
                let previous = text.index(before: keyStart)
                let char = text[previous]
                guard char.isLetter || char.isNumber || char == "-" || char == "_" else { break }
                keyStart = previous
            }
            let key = String(text[keyStart ..< equals])

            let quoteStart = text.index(after: valueStart)
            guard let quoteEnd = text[quoteStart...].firstIndex(of: "\"") else { break }
            if !key.isEmpty {
                result[key] = String(text[quoteStart ..< quoteEnd])
            }
            index = text.index(after: quoteEnd)
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Chunk reader

/// The chunk loop behind `parseStreaming`: takes the file's chunks (or the
/// reason there are no more), splits complete lines out of the carry buffer
/// and accumulates entries until a batch fills.
///
/// Its lifecycle is one `Phase`, not flags: the carry buffer exists only
/// while reading, and how the read ended (completed, failed, cancelled) is
/// part of the terminal state rather than collapsed into "finished". All
/// transitions happen in `step`, and a terminal phase accepts no input.
/// It does no I/O itself, so every transition is testable with plain data.
nonisolated struct M3UChunkReader {
    enum Input {
        case chunk(Data)
        case endOfFile
        case readFailed(any Error)
        case cancelled
    }

    enum Phase {
        /// Reading; `carry` holds the partial line after the last newline.
        case reading(carry: Data)
        /// End of file reached and every entry delivered.
        case completed
        /// The read stopped early: a read error or a rejected line.
        case failed(any Error)
        /// The task was cancelled before the file was read to the end.
        case cancelled

        var isReading: Bool {
            if case .reading = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .reading(carry: Data())
    private(set) var totalCount = 0
    private let batchSize: Int
    private var state = M3UParser.ParseState()
    private var batch: [M3UEntry] = []
    /// Bytes of the file already handed to the line loop, excluding the
    /// block currently being walked.
    private var consumedBase = 0

    init(batchSize: Int) {
        self.batchSize = batchSize
        batch.reserveCapacity(batchSize)
    }

    /// Applies one input and returns whatever batches it completed —
    /// usually none or one; at end of file, also the trailing partial batch.
    mutating func step(_ input: Input, onHeader: ((M3UHeader) -> Void)?) -> [M3UParser.ReadyBatch] {
        guard case var .reading(carry) = phase else {
            assertionFailure("M3U reader received input after it finished")
            return []
        }
        // Release the phase's reference so `carry` is uniquely owned and
        // appends in place; every path below assigns the next phase.
        phase = .reading(carry: Data())

        switch input {
        case let .chunk(chunk):
            carry.append(chunk)
            // Split everything up to the last newline into lines; the tail
            // (a partial line) is carried into the next chunk.
            guard let lastNewline = carry.lastIndex(of: UInt8(ascii: "\n")) else {
                phase = carry.count > M3UParser.maximumLineBytes
                    ? .failed(M3UParseError.lineTooLong(limit: M3UParser.maximumLineBytes))
                    : .reading(carry: carry)
                return []
            }
            let processable = carry.subdata(in: carry.startIndex ..< lastNewline)
            let tail = carry.subdata(in: carry.index(after: lastNewline) ..< carry.endIndex)
            guard let ready = consume(processable, onHeader: onHeader),
                  tail.count <= M3UParser.maximumLineBytes
            else {
                phase = .failed(M3UParseError.lineTooLong(limit: M3UParser.maximumLineBytes))
                return []
            }
            phase = .reading(carry: tail)
            return ready

        case .endOfFile:
            // The whole remainder is one final line.
            guard var ready = consume(carry, onHeader: onHeader) else {
                phase = .failed(M3UParseError.lineTooLong(limit: M3UParser.maximumLineBytes))
                return []
            }
            if !batch.isEmpty {
                ready.append((batch, consumedBase))
                batch = []
            }
            phase = .completed
            return ready

        case let .readFailed(error):
            phase = .failed(error)
            return []

        case .cancelled:
            phase = .cancelled
            return []
        }
    }

    /// Parses a block of complete lines into the current batch, returning
    /// the batches it filled, or nil if a line exceeds the maximum length.
    private mutating func consume(_ processable: Data, onHeader: ((M3UHeader) -> Void)?) -> [M3UParser.ReadyBatch]? {
        let blockStart = processable.startIndex
        defer { consumedBase += processable.count + 1 }

        var ready: [M3UParser.ReadyBatch] = []
        for lineData in processable.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard lineData.count <= M3UParser.maximumLineBytes else { return nil }
            // Latin-1 fallback: it never fails, so a stray non-UTF-8 line
            // (older provider exports) degrades to mojibake instead of
            // dropping the entry.
            let raw = String(bytes: lineData, encoding: .utf8)
                ?? String(bytes: lineData, encoding: .isoLatin1)
            guard let line = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }

            if let entry = state.consume(line: line, onHeader: onHeader) {
                batch.append(entry)
                totalCount += 1
                if batch.count >= batchSize {
                    ready.append((batch, consumedBase + (lineData.endIndex - blockStart)))
                    // Handing the array out shares its buffer, so
                    // `removeAll(keepingCapacity:)` would have to copy;
                    // a fresh right-sized one instead of re-growing 0→2,000.
                    batch = []
                    batch.reserveCapacity(batchSize)
                }
            }
        }
        return ready
    }
}
