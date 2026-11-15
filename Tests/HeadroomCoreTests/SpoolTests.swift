import Foundation
import Testing
@testable import HeadroomCore

private func makeSpool() throws -> (Spool, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (Spool(url: dir.appendingPathComponent("spool.jsonl")), dir)
}

@Suite struct SpoolTests {
    @Test func appendThenDrainTwice() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let records: [SpoolRecord] = [
            .tag(ts: 1, text: "build"),
            .command(ts: 2, exe: "swift", seconds: 3.5),
            .agentSession(ts: 3, tool: "claude", sessionId: "s1", model: nil, rootPid: 42, rootStart: 99),
        ]
        for r in records { #expect(spool.append(r)) }
        let first = spool.drain()
        #expect(first.records.isEmpty)
        #expect(first.malformed == 0)
        let second = spool.drain()
        #expect(second.records == records)
        #expect(second.malformed == 0)
        #expect(spool.drain().records.isEmpty)
    }

    @Test func newRecordsRoundTrip() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let records: [SpoolRecord] = [
            .agentWarning(ts: 5, trigger: .swapGrowing),
            .agentWarning(ts: 5.5, trigger: nil),
            .containerIntent(ts: 6, rootPid: 77, rootStart: 1_700_000_000_000_000),
        ]
        for r in records { #expect(spool.append(r)) }
        _ = spool.drain()
        let result = spool.drain()
        #expect(result.records == records)
        #expect(result.malformed == 0)
    }

    @Test func agentWarningWithoutTriggerStillDecodes() throws {
        let decoded = try JSONDecoder().decode(SpoolRecord.self, from: Data(#"{"ts":5,"type":"agentWarning"}"#.utf8))
        #expect(decoded == .agentWarning(ts: 5, trigger: nil))
        let leftovers = try JSONDecoder().decode(
            SpoolRecord.self, from: Data(#"{"trigger":"leftovers","ts":5,"type":"agentWarning"}"#.utf8))
        #expect(leftovers == .agentWarning(ts: 5, trigger: .leftovers))
    }

    @Test func phase1RecorderSkipsNewRecords() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        try (#"{"type":"futureRecord","ts":1}"# + "\n").write(to: spool.url, atomically: true, encoding: .utf8)
        _ = spool.drain()
        let result = spool.drain()
        #expect(result.records.isEmpty)
        #expect(result.malformed == 1)
    }

    @Test func malformedLinesSkipped() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good1 = #"{"type":"tag","ts":1,"text":"a"}"#
        let good2 = #"{"type":"command","ts":2,"exe":"ls","seconds":0.5}"#
        let content = [good1, #"{"type":"tag""#, "garbage", good2].joined(separator: "\n") + "\n"
        try content.write(to: spool.url, atomically: true, encoding: .utf8)
        _ = spool.drain()
        let result = spool.drain()
        #expect(result.records == [.tag(ts: 1, text: "a"), .command(ts: 2, exe: "ls", seconds: 0.5)])
        #expect(result.malformed == 2)
    }

    @Test func truncatedLastLineIsMalformed() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        try (#"{"type":"tag","ts":1,"text":"a"}"# + "\n" + #"{"type":"tag","ts":2"#)
            .write(to: spool.url, atomically: true, encoding: .utf8)
        _ = spool.drain()
        let result = spool.drain()
        #expect(result.records.count == 1)
        #expect(result.malformed == 1)
    }

    @Test func oversizedRecordRejected() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!spool.append(.tag(ts: 1, text: String(repeating: "x", count: 4096))))
        #expect(!FileManager.default.fileExists(atPath: spool.url.path))
    }

    @Test func limitIncludesTrailingNewline() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let overhead = try JSONEncoder().encode(SpoolRecord.tag(ts: 1, text: "")).count + 1
        #expect(spool.append(.tag(ts: 1, text: String(repeating: "x", count: 4096 - overhead))))
        #expect(!spool.append(.tag(ts: 1, text: String(repeating: "x", count: 4097 - overhead))))
        let size = try FileManager.default.attributesOfItem(atPath: spool.url.path)[.size] as? Int
        #expect(size == 4096)
    }

    @Test func missingFileIsEmpty() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = spool.drain()
        #expect(result.records.isEmpty)
        #expect(result.malformed == 0)
    }

    @Test func newlineInTagStaysOnOneLine() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = SpoolRecord.tag(ts: 1, text: "a\nb\r\nc")
        #expect(spool.append(record))
        let raw = try String(contentsOf: spool.url, encoding: .utf8)
        #expect(raw.filter { $0 == "\n" }.count == 1)
        #expect(raw.hasSuffix("\n"))
        _ = spool.drain()
        #expect(spool.drain().records == [record])
    }

    @Test func recordsRoundTripWithModel() throws {
        let record = SpoolRecord.agentSession(ts: 1, tool: "codex", sessionId: "s", model: "m", rootPid: -1, rootStart: UInt64.max)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(SpoolRecord.self, from: data) == record)
    }

    @Test func unreadableIngestingIsNotOverwritten() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingesting = URL(fileURLWithPath: spool.url.path + ".ingesting")
        try FileManager.default.createDirectory(at: ingesting, withIntermediateDirectories: true)
        let record = SpoolRecord.tag(ts: 1, text: "keep me")
        #expect(spool.append(record))

        let result = spool.drain()
        #expect(result.records.isEmpty)
        #expect(result.malformed == 0)
        #expect(result.drainFailed)
        let raw = try String(contentsOf: spool.url, encoding: .utf8)
        #expect(raw.contains("keep me"))

        try FileManager.default.removeItem(at: ingesting)
        #expect(!spool.drain().drainFailed)
        let recovered = spool.drain()
        #expect(recovered.records == [record])
        #expect(!recovered.drainFailed)
    }

    @Test func appendRejectedWhenSpoolIsOversized() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fd = open(spool.url.path, O_WRONLY | O_CREAT, 0o600)
        #expect(fd >= 0)
        #expect(ftruncate(fd, 16 * 1024 * 1024 + 1) == 0)
        close(fd)
        #expect(!spool.append(.tag(ts: 1, text: "x")))
        let size = try FileManager.default.attributesOfItem(atPath: spool.url.path)[.size] as? Int
        #expect(size == 16 * 1024 * 1024 + 1)
    }

    @Test func concurrentAppends() throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<200 {
                spool.append(.tag(ts: Double(t), text: "\(t)-\(i)"))
            }
        }
        _ = spool.drain()
        let result = spool.drain()
        #expect(result.malformed == 0)
        #expect(result.records.count == 1600)
        let expected = Set((0..<8).flatMap { t in (0..<200).map { "\(t)-\($0)" } })
        let actual = Set(result.records.compactMap { record -> String? in
            if case let .tag(_, text) = record { return text }
            return nil
        })
        #expect(actual == expected)
    }
}
