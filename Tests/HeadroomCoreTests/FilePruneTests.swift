import Darwin
import Foundation
import Testing

@testable import HeadroomCore

@Suite struct FilePruneTests {
    private let now = 1_000_000.0
    private let day = 86_400.0

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(_ url: URL, mtime: Double) throws {
        try Data("x".utf8).write(to: url)
        setMtime(url, mtime)
    }

    private func setMtime(_ url: URL, _ mtime: Double) {
        var times = [timeval(tv_sec: Int(mtime), tv_usec: 0), timeval(tv_sec: Int(mtime), tv_usec: 0)]
        lutimes(url.path, &times)
    }

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    @Test func oldFileIsDeletedAndFreshFileKept() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appending(path: "old")
        let fresh = dir.appending(path: "fresh")
        try file(old, mtime: now - day - 1)
        try file(fresh, mtime: now - day + 60)
        #expect(FilePrune.pruneOldFiles(in: dir, now: now, maxAge: day) == 1)
        #expect(!exists(old))
        #expect(exists(fresh))
    }

    @Test func entrySymlinkIsKeptAndTargetSurvives() throws {
        let dir = try scratch()
        let outside = try scratch()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let target = outside.appending(path: "target")
        try file(target, mtime: now - 10 * day)
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        setMtime(link, now - 10 * day)
        #expect(FilePrune.pruneOldFiles(in: dir, now: now, maxAge: day) == 0)
        #expect(exists(link))
        #expect(exists(target))
    }

    @Test func subdirectoryIsKeptAndNotRecursed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let inner = sub.appending(path: "inner")
        try file(inner, mtime: now - 10 * day)
        setMtime(sub, now - 10 * day)
        #expect(FilePrune.pruneOldFiles(in: dir, now: now, maxAge: day) == 0)
        #expect(exists(sub))
        #expect(exists(inner))
    }

    @Test func missingDirectoryGivesZero() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FilePrune.pruneOldFiles(in: dir.appending(path: "missing"), now: now, maxAge: day) == 0)
        let plain = dir.appending(path: "plain")
        try file(plain, mtime: now - 10 * day)
        #expect(FilePrune.pruneOldFiles(in: plain, now: now, maxAge: day) == 0)
        #expect(exists(plain))
    }

    @Test func symlinkedDirectoryGivesZeroAndTargetFilesSurvive() throws {
        let root = try scratch()
        let real = try scratch()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: real)
        }
        let victim = real.appending(path: "old")
        try file(victim, mtime: now - 10 * day)
        let pretool = root.appending(path: "pretool")
        try FileManager.default.createSymbolicLink(at: pretool, withDestinationURL: real)
        #expect(FilePrune.pruneOldFiles(in: pretool, now: now, maxAge: day) == 0)
        #expect(exists(victim))
    }
}
