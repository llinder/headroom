public enum Workdays {
    /// Awake time is what was recorded plus the gaps where the recorder missed an awake machine; sleep is
    /// excluded because the machine wasn't working.
    public static func workdays(_ coverage: [DayCoverage], minAwakeSeconds: Double) -> [String] {
        coverage.filter { $0.recorded + $0.gap >= minAwakeSeconds }.map(\.day)
    }
}
