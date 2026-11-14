import Foundation

/// A reference workload measured elsewhere, written by the user for the report's comparison page.
public struct Baseline: Codable, Sendable, Equatable {
    public var label: String
    public var cores: Int
    public var memoryGB: Double
    public var cpuP95: Double?
    public var peakMemoryUsedGB: Double?
    public var cacheGB: Double?
    public var diskUsedGB: Double?
    public var concurrentAgents: Int?
    public var source: String?

    public init(
        label: String, cores: Int, memoryGB: Double, cpuP95: Double? = nil, peakMemoryUsedGB: Double? = nil,
        cacheGB: Double? = nil, diskUsedGB: Double? = nil, concurrentAgents: Int? = nil, source: String? = nil
    ) {
        self.label = label
        self.cores = cores
        self.memoryGB = memoryGB
        self.cpuP95 = cpuP95
        self.peakMemoryUsedGB = peakMemoryUsedGB
        self.cacheGB = cacheGB
        self.diskUsedGB = diskUsedGB
        self.concurrentAgents = concurrentAgents
        self.source = source
    }

    /// The file is optional, so a missing one is silent; an unreadable one is skipped with a warning.
    public static func load(from url: URL) -> (Baseline?, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            return (try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: url)), nil)
        } catch {
            return (nil, "ignoring \(url.path): \(error.localizedDescription)")
        }
    }
}
