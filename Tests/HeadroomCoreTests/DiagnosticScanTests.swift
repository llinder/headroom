import Foundation
import Testing

@testable import HeadroomCore

struct DiagnosticScanTests {
    @Test func diagnosticScanFiltersByNameAndTime() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let since = Date(timeIntervalSince1970: 1_800_000_000)
        func touch(_ name: String, at: Date) throws {
            let url = dir.appending(path: name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        }
        try touch("JetsamEvent-2026-11-14.ips", at: since.addingTimeInterval(60))
        try touch("x.hang", at: since.addingTimeInterval(120))
        try touch("y.spin", at: since.addingTimeInterval(180))
        try touch("foo.diag", at: since.addingTimeInterval(60))
        try touch("JetsamEvent-2026-11-01.ips", at: since.addingTimeInterval(-60))
        try touch("Other-2026-11-14.ips", at: since.addingTimeInterval(60))

        var scanner = DiagnosticScanner(directories: [dir, dir.appending(path: "missing")])
        let found = scanner.scan(since: since).sorted { $0.ts < $1.ts }
        #expect(found.map(\.kind) == ["jetsam", "hang", "hang"])
        #expect(found.map(\.file) == ["JetsamEvent-2026-11-14.ips", "x.hang", "y.spin"])
        #expect(found[0].ts == since.timeIntervalSince1970 + 60)

        // The same files are not reported twice, even when the caller rescans from the same point.
        #expect(scanner.scan(since: since).isEmpty)
        try touch("z.hang", at: since.addingTimeInterval(240))
        #expect(scanner.scan(since: since).map(\.file) == ["z.hang"])
    }
}
