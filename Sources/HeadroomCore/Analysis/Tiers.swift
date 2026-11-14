import Foundation

/// The configurations a recommendation rounds up to. Memory is in GB as Apple sells it (binary); storage is in
/// GB as Apple sells it (decimal).
public struct Tiers: Codable, Sendable, Equatable {
    public var memoryGB: [Int]
    public var cores: [Int]
    public var storageGB: [Int]

    public init(memoryGB: [Int], cores: [Int], storageGB: [Int]) {
        self.memoryGB = memoryGB
        self.cores = cores
        self.storageGB = storageGB
    }

    public static let defaults = Tiers(
        memoryGB: [16, 24, 32, 36, 48, 64, 96, 128], cores: [8, 10, 12, 14, 16],
        storageGB: [512, 1024, 2048, 4096, 8192])

    /// A missing file is the normal state, so it yields the defaults without a warning.
    public static func load(from url: URL) -> (Tiers, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (defaults, nil) }
        let tiers: Tiers
        do {
            tiers = try JSONDecoder().decode(Tiers.self, from: Data(contentsOf: url))
        } catch {
            return (defaults, "ignoring \(url.path): \(error.localizedDescription)")
        }
        // An empty or non-positive list would leave a resource with nothing to recommend.
        for list in [tiers.memoryGB, tiers.cores, tiers.storageGB] where list.isEmpty || list.contains(where: { $0 <= 0 }) {
            return (defaults, "ignoring \(url.path): every tier list needs at least one positive value")
        }
        return (Tiers(memoryGB: tiers.memoryGB.sorted(), cores: tiers.cores.sorted(), storageGB: tiers.storageGB.sorted()), nil)
    }
}
