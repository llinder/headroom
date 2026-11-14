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

    @Test func concurrentAppends() async throws {
        let (spool, dir) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: dir) }
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<200 {
                        spool.append(.tag(ts: Double(t * 1000 + i), text: "task \(t) record \(i)"))
                    }
                }
            }
        }
        _ = spool.drain()
        let result = spool.drain()
        #expect(result.records.count == 1600)
        #expect(result.malformed == 0)
    }
}
