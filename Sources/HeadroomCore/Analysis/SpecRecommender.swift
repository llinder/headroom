public struct SpecRecommendation: Equatable, Sendable {
    public var memoryGB: Int
    public var cores: Int?
    public var storageGB: Int
    public var reasons: [String]

    public init(memoryGB: Int, cores: Int?, storageGB: Int, reasons: [String]) {
        self.memoryGB = memoryGB
        self.cores = cores
        self.storageGB = storageGB
        self.reasons = reasons
    }

    public var headline: String {
        let parts = ["\(memoryGB) GB memory", cores.map { "\($0)+ cores" }, "\(SpecRecommender.storageLabel(storageGB)) storage"]
        return "Recommended: " + parts.compactMap { $0 }.joined(separator: ", ")
    }
}

public enum SpecRecommender {
    private static let memoryHeadroom = 1.25
    private static let storageHeadroom = 1.2
    private static let cpuStepUpSeconds = 1800.0
    private static let bytesPerGiB = 1_073_741_824.0
    private static let exceeds = "exceeds the largest configuration"

    /// `currentMemoryGB` is what memory falls back to when there are no daily peaks to size it from; without
    /// it the smallest tier is used. A nil `growthBytesPerDay` means growth hasn't been measured yet.
    public static func recommend(
        dailyPeakMemoryBytes: [Double], medianSaturatedSeconds: Double, currentCores: Int, currentMemoryGB: Int? = nil,
        usedBytes: UInt64, growthBytesPerDay: Double?, tiers: Tiers
    ) -> SpecRecommendation {
        let (memoryGB, memoryReason) = memory(dailyPeakMemoryBytes, currentMemoryGB, tiers.memoryGB.sorted())
        let (cores, coresReason) = cpu(medianSaturatedSeconds, currentCores, tiers.cores.sorted())
        let (storageGB, storageReason) = storage(usedBytes, growthBytesPerDay, tiers.storageGB.sorted())
        return SpecRecommendation(
            memoryGB: memoryGB, cores: cores, storageGB: storageGB, reasons: [memoryReason, coresReason, storageReason])
    }

    /// Whole terabytes show as TB, whether the tier is written in binary (1024) or decimal (1000) multiples.
    static func storageLabel(_ gb: Int) -> String {
        if gb >= 1024, gb % 1024 == 0 { return "\(gb / 1024) TB" }
        if gb >= 1000, gb % 1000 == 0 { return "\(gb / 1000) TB" }
        return "\(gb) GB"
    }

    /// The nearest-rank 95th percentile of daily peaks: a heavy day that recurs, not the single worst outlier.
    private static func memory(_ peaks: [Double], _ current: Int?, _ tiers: [Int]) -> (Int, String) {
        let sorted = peaks.sorted()
        guard !sorted.isEmpty else {
            let fallback = current.map { c in tiers.first { $0 >= c } ?? c } ?? tiers.first ?? 0
            return (fallback, "Not enough data yet to size memory.")
        }
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        let p95GB = sorted[max(rank, 1) - 1] / bytesPerGiB
        let peak = "Peak memory demand reached \(Wording.decimal(p95GB, places: 1)) GB on a typical heavy day"
        let needed = p95GB * memoryHeadroom
        guard let tier = tiers.first(where: { Double($0) >= needed }) else {
            let largest = tiers.last ?? 0
            return (largest, "\(peak); with 25% headroom that \(exceeds), \(largest) GB.")
        }
        return (tier, "\(peak); \(tier) GB is the smallest option with at least 25% headroom.")
    }

    private static func cpu(_ medianSeconds: Double, _ current: Int, _ tiers: [Int]) -> (Int?, String) {
        guard medianSeconds > cpuStepUpSeconds else {
            return (
                nil,
                "The processor was fully busy for half an hour or less on a median workday, so \(current) cores are enough."
            )
        }
        let busy = "The processor was fully busy for \(Wording.hours(medianSeconds)) hours on a median workday"
        guard let tier = tiers.first(where: { $0 > current }) else {
            let largest = tiers.last ?? current
            return (largest, "\(busy); more than \(current) cores \(exceeds), \(largest) cores.")
        }
        return (tier, "\(busy), so step up from \(current) to \(tier) cores.")
    }

    /// Shrinking usage is projected as flat: a recommendation shouldn't count on space being freed.
    private static func storage(_ used: UInt64, _ growthPerDay: Double?, _ tiers: [Int]) -> (Int, String) {
        let usedGB = Double(used) / 1e9
        let growthGB = max(growthPerDay ?? 0, 0) / 1e9
        let neededGB = (usedGB + 365 * growthGB) * storageHeadroom
        let needed = Wording.decimal(neededGB, places: 0)
        let holds = "Storage holds \(Wording.decimal(usedGB, places: 0)) GB"
        let trend =
            if growthPerDay == nil {
                "\(holds), growth not yet measured; that plus 20% needs \(needed) GB"
            } else if growthGB > 0 {
                "\(holds) and grows \(Wording.decimal(growthGB, places: 1)) GB a day; a year of growth plus 20% needs \(needed) GB"
            } else {
                "\(holds) and isn't growing; that plus 20% needs \(needed) GB"
            }
        guard let tier = tiers.first(where: { Double($0) >= neededGB }) else {
            let largest = tiers.last ?? 0
            return (largest, "\(trend), which \(exceeds), \(storageLabel(largest)).")
        }
        return (tier, "\(trend), so \(storageLabel(tier)).")
    }
}
