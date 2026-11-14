public enum Schema {
    // Append-only: entry N upgrades a database from version N to N+1.
    private static let migrations: [String] = [
        """
        CREATE TABLE machines(
            machine_id TEXT PRIMARY KEY, model TEXT, serial_hash TEXT,
            perf_cores INTEGER, eff_cores INTEGER, ram_bytes INTEGER, disk_bytes INTEGER,
            first_seen INTEGER, last_seen INTEGER
        );
        CREATE TABLE samples(
            machine_id TEXT NOT NULL, ts INTEGER NOT NULL,
            cpu_user REAL, cpu_sys REAL, per_core BLOB,
            load1 REAL, load5 REAL, load15 REAL,
            mem_total INTEGER, mem_used INTEGER, mem_app INTEGER, mem_wired INTEGER,
            mem_compressed INTEGER, mem_free INTEGER,
            pressure INTEGER, memorystatus_level INTEGER NULL,
            swap_used INTEGER, swap_total INTEGER, swapins INTEGER, swapouts INTEGER,
            pageins INTEGER, pageouts INTEGER, ssd_read INTEGER, ssd_write INTEGER,
            disk_free INTEGER, disk_capacity INTEGER,
            thermal INTEGER, limit_flags INTEGER,
            active_agents INTEGER, idle_agents INTEGER,
            self_cpu REAL, self_footprint INTEGER,
            PRIMARY KEY(machine_id, ts)
        );
        CREATE TABLE group_samples(
            machine_id TEXT NOT NULL, ts INTEGER NOT NULL,
            group_id TEXT, cpu_seconds REAL, footprint INTEGER, disk_write INTEGER, proc_count INTEGER
        );
        CREATE INDEX group_samples_machine_ts ON group_samples(machine_id, ts);
        CREATE TABLE top_procs_1m(
            machine_id TEXT NOT NULL, ts INTEGER NOT NULL,
            kind TEXT, rank INTEGER, name TEXT, group_id TEXT, value REAL
        );
        CREATE INDEX top_procs_1m_machine_ts ON top_procs_1m(machine_id, ts);
        CREATE TABLE rollup(
            machine_id TEXT NOT NULL, resolution INTEGER NOT NULL, ts INTEGER NOT NULL,
            metric TEXT NOT NULL, avg REAL, max REAL, p95 REAL,
            PRIMARY KEY(machine_id, resolution, ts, metric)
        );
        CREATE TABLE limit_seconds(
            machine_id TEXT NOT NULL, resolution INTEGER NOT NULL, ts INTEGER NOT NULL,
            kind TEXT NOT NULL, seconds REAL,
            PRIMARY KEY(machine_id, resolution, ts, kind)
        );
        CREATE TABLE agent_histogram(
            machine_id TEXT NOT NULL, ts INTEGER NOT NULL, active_agents INTEGER NOT NULL,
            seconds REAL, memory_limited REAL, cpu_saturated REAL,
            PRIMARY KEY(machine_id, ts, active_agents)
        );
        CREATE TABLE events(
            machine_id TEXT NOT NULL, ts INTEGER NOT NULL, kind TEXT, payload TEXT
        );
        CREATE INDEX events_machine_ts ON events(machine_id, ts);
        CREATE TABLE coverage(
            machine_id TEXT NOT NULL, day TEXT NOT NULL,
            seconds_recorded REAL, seconds_asleep REAL, seconds_gap REAL, gaps TEXT,
            PRIMARY KEY(machine_id, day)
        );
        CREATE TABLE agent_runs(
            run_id INTEGER PRIMARY KEY AUTOINCREMENT,
            machine_id TEXT NOT NULL, tool TEXT, root_pid INTEGER, root_start INTEGER,
            started INTEGER, ended INTEGER NULL,
            UNIQUE(machine_id, root_pid, root_start)
        );
        CREATE TABLE agent_run_sessions(
            run_id INTEGER NOT NULL, session_id TEXT NOT NULL, model TEXT NULL, first_seen INTEGER,
            PRIMARY KEY(run_id, session_id)
        );
        CREATE TABLE run_usage(
            run_id INTEGER NOT NULL, ts INTEGER NOT NULL,
            cpu_seconds REAL, peak_footprint INTEGER, disk_write INTEGER, active_seconds REAL,
            PRIMARY KEY(run_id, ts)
        );
        """,
    ]

    public static func migrate(_ db: Database) throws {
        // The version is read under the write lock so a concurrent migrator that lost the race sees the winner's result.
        try db.transaction {
            try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
            let current = try storedVersion(db)
            // An older build would otherwise write rows into tables whose meaning a newer one has changed.
            guard current <= migrations.count else {
                throw DatabaseError.open(
                    "database schema v\(current) is newer than this headroom (v\(migrations.count))")
            }
            guard current < migrations.count else { return }
            for index in current..<migrations.count {
                try db.exec(migrations[index])
            }
            let upsert = try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)")
            upsert.bind(1, String(migrations.count))
            _ = try upsert.step()
        }
    }

    private static func storedVersion(_ db: Database) throws(DatabaseError) -> Int {
        let stmt = try db.prepare("SELECT value FROM meta WHERE key='schema_version'")
        return try stmt.step() ? Int(stmt.string(0)) ?? 0 : 0
    }
}
