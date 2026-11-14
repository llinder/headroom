import Foundation
import Testing
@testable import HeadroomCore

private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("headroom-test-\(UUID().uuidString).db").path
}

private func column(_ db: Database, _ sql: String) throws(DatabaseError) -> [String] {
    let stmt = try db.prepare(sql)
    var out: [String] = []
    while try stmt.step() { out.append(stmt.string(0)) }
    return out
}

@Suite struct DatabaseTests {
    @Test func migrateCreatesAllTables() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try Database(path: path, readOnly: false)
        try Schema.migrate(db)
        let tables = Set(try column(db, "SELECT name FROM sqlite_master WHERE type='table'"))
        let expected: Set<String> = [
            "machines", "samples", "group_samples", "top_procs_1m", "rollup", "limit_seconds",
            "agent_histogram", "events", "coverage", "agent_runs", "agent_run_sessions",
            "run_usage", "meta",
        ]
        #expect(expected.isSubset(of: tables))
        #expect(try column(db, "PRAGMA journal_mode") == ["wal"])
    }

    @Test func migrateIsIdempotent() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try Database(path: path, readOnly: false)
        try Schema.migrate(db)
        try Schema.migrate(db)
        #expect(try column(db, "SELECT value FROM meta WHERE key='schema_version'") == ["1"])
    }

    @Test func readOnlyRejectsWrites() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Schema.migrate(Database(path: path, readOnly: false))
        let db = try Database(path: path, readOnly: true)
        #expect {
            try db.exec("INSERT INTO meta VALUES('k','v')")
        } throws: { error in
            guard let e = error as? DatabaseError, case .sqlite = e else { return false }
            return true
        }
    }

    @Test func statementRoundTripsTypesAndNulls() throws {
        let db = try Database(path: ":memory:", readOnly: false)
        try db.exec("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB)")
        let insert = try db.prepare("INSERT INTO t VALUES(?,?,?,?)")
        insert.bind(1, Int64(42))
        insert.bind(2, 1.5)
        insert.bind(3, "héllo")
        insert.bind(4, Data([1, 2, 3]))
        #expect(try insert.step() == false)
        insert.reset()
        insert.bind(1, Int64?.none)
        insert.bind(2, Double?.none)
        insert.bind(3, String?.none)
        insert.bind(4, Data?.none)
        #expect(try insert.step() == false)

        let select = try db.prepare("SELECT i, d, s, b FROM t ORDER BY rowid")
        #expect(try select.step())
        #expect(select.int64(0) == 42)
        #expect(select.double(1) == 1.5)
        #expect(select.string(2) == "héllo")
        #expect(select.data(3) == Data([1, 2, 3]))
        #expect(try select.step())
        #expect((0..<4).allSatisfy { select.isNull(Int32($0)) })
        #expect(try select.step() == false)
    }

    @Test func resetClearsBindings() throws {
        let db = try Database(path: ":memory:", readOnly: false)
        try db.exec("CREATE TABLE t(i INTEGER)")
        let insert = try db.prepare("INSERT INTO t VALUES(?)")
        insert.bind(1, Int64(7))
        _ = try insert.step()
        insert.reset()
        _ = try insert.step()
        #expect(try column(db, "SELECT count(*) FROM t WHERE i IS NULL") == ["1"])
    }

    @Test func transactionRollsBackOnErrorAndRethrows() throws {
        struct Boom: Error {}
        let db = try Database(path: ":memory:", readOnly: false)
        try db.exec("CREATE TABLE t(i INTEGER)")
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.exec("INSERT INTO t VALUES(1)")
                throw Boom()
            }
        }
        #expect(try column(db, "SELECT count(*) FROM t") == ["0"])
        try db.transaction { try db.exec("INSERT INTO t VALUES(1)") }
        #expect(try column(db, "SELECT count(*) FROM t") == ["1"])
    }

    @Test func openingMissingFileReadOnlyThrowsOpenError() {
        let path = tempDBPath()
        #expect {
            _ = try Database(path: path, readOnly: true)
        } throws: { error in
            guard let e = error as? DatabaseError, case .open = e else { return false }
            return true
        }
    }
}
