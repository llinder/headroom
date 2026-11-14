/// Kernel counters can wrap or reset (sleep/wake, pid reuse); a backwards step counts as no activity.
public func counterDelta(_ previous: UInt64, _ current: UInt64) -> UInt64 {
    current >= previous ? current - previous : 0
}
