import Foundation

public struct DockerEngine: Sendable, Equatable {
    public let context: String
    public let socketPath: String
    /// Set for the engine found through `DOCKER_HOST`, which has no Docker context: cleanup commands set the
    /// variable instead of naming a context.
    public let dockerHost: String?

    public init(context: String, socketPath: String, dockerHost: String? = nil) {
        self.context = context
        self.socketPath = socketPath
        self.dockerHost = dockerHost
    }
}

public enum DockerEngines {
    private struct ContextMeta: Decodable {
        struct Endpoints: Decodable {
            struct Docker: Decodable { let Host: String? }
            let docker: Docker?
        }
        let Name: String?
        let Endpoints: Endpoints?
    }

    private static let unixPrefix = "unix://"

    public static func discover(
        home: URL,
        environment: [String: String],
        systemSocket: String = "/var/run/docker.sock"
    ) -> [DockerEngine] {
        var candidates = contextCandidates(home: home).map { (context: $0.context, path: $0.path, fromEnvironment: false) }
        candidates.append((context: "default", path: systemSocket, fromEnvironment: false))
        if let host = environment["DOCKER_HOST"], host.hasPrefix(unixPrefix) {
            candidates.append((context: "env", path: String(host.dropFirst(unixPrefix.count)), fromEnvironment: true))
        }

        var seen = Set<String>()
        var engines: [DockerEngine] = []
        for candidate in candidates {
            guard let resolved = realPath(candidate.path), seen.insert(resolved).inserted else { continue }
            engines.append(DockerEngine(
                context: candidate.context, socketPath: resolved,
                dockerHost: candidate.fromEnvironment ? unixPrefix + resolved : nil))
        }
        return engines
    }

    private static func contextCandidates(home: URL) -> [(context: String, path: String)] {
        let meta = home.appendingPathComponent(".docker/contexts/meta", isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: meta.path)) ?? []
        let decoder = JSONDecoder()
        var found: [(context: String, path: String)] = []
        for dir in dirs {
            let file = meta.appendingPathComponent(dir).appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: file),
                  let parsed = try? decoder.decode(ContextMeta.self, from: data),
                  let name = parsed.Name,
                  let host = parsed.Endpoints?.docker?.Host,
                  host.hasPrefix(unixPrefix)
            else { continue }
            found.append((context: name, path: String(host.dropFirst(unixPrefix.count))))
        }
        return found.sorted { ($0.context, $0.path) < ($1.context, $1.path) }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
