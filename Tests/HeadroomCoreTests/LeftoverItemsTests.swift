import Foundation
import Testing

@testable import HeadroomCore

private func c(_ id: String, _ name: String, image: String = "img", labels: [String: String] = [:], state: String = "running")
    -> DockerContainer
{
    DockerContainer(id: id, names: [name], image: image, labels: labels, state: state)
}

struct LeftoverItemsTests {
    @Test func groupsKindComposeTestcontainersAndSingles() {
        let cs = [
            c("k1", "dev-control-plane", image: "kindest/node", labels: ["io.x-k8s.kind.cluster": "dev"]),
            c("k2", "dev-worker", image: "kindest/node", labels: ["io.x-k8s.kind.cluster": "dev"]),
            c("c1", "web-1", labels: ["com.docker.compose.project": "shop"]),
            c("c2", "db-1", labels: ["com.docker.compose.project": "shop"]),
            c("t1", "pg", labels: ["org.testcontainers": "true", "org.testcontainers.sessionId": "s1"]),
            c("t2", "redis", labels: ["org.testcontainers": "true", "org.testcontainers.sessionId": "s1"]),
            c("s1", "scratch"),
            c("x1", "stopped", state: "exited"),
        ]
        let r = LeftoverGrouper.group(cs, engine: "orbstack", ignore: IgnoreRules())
        #expect(r.items.map(\.key) == [
            "orbstack/kind/dev", "orbstack/compose/shop", "orbstack/testcontainers/s1", "orbstack/container/s1",
        ])
        #expect(r.items[0].name == "dev")
        #expect(r.items[2].sessionId == "s1")
        #expect(r.items[3].name == "scratch")
        #expect(r.items[0].cleanup == [
            "docker --context 'orbstack' stop 'dev-control-plane' 'dev-worker'",
            "DOCKER_CONTEXT='orbstack' kind delete cluster --name 'dev'",
        ])
        #expect(r.items[2].cleanup == ["docker --context 'orbstack' rm -f 't1' 't2'"])
    }

    @Test func builtInIgnores() {
        let cs = [
            c("a", "buildx_buildkit_b0", image: "moby/buildkit:x"),
            c("b", "reg", image: "registry:3"),
            c("r", "testcontainers-ryuk-1", labels: ["org.testcontainers": "true", "org.testcontainers.sessionId": "s9"]),
            c("p", "pod", labels: ["io.kubernetes.pod.name": "x"]),
            c("u", "reuse", labels: ["org.testcontainers.reuse.enable": "true"]),
            c("kr", "kind-registry"),
        ]
        let r = LeftoverGrouper.group(cs, engine: "e", ignore: IgnoreRules())
        #expect(r.items.isEmpty)
        #expect(r.reapers == ["s9"])
    }

    @Test func configIgnoreByImageAndLabel() {
        let cs = [
            c("a", "one", image: "corp/tool:1"),
            c("b", "two", labels: ["keepme": "1"]),
            c("d", "three", labels: ["tier": "infra"]),
            c("e", "four", labels: ["tier": "app"]),
            c("f", "tmp-x"),
        ]
        let rules = IgnoreRules(names: ["tmp-*"], images: ["corp/*"], labels: ["keepme", "tier=infra"])
        let r = LeftoverGrouper.group(cs, engine: "e", ignore: rules)
        #expect(r.items.map(\.name) == ["four"])
    }

    @Test func lifetimeParsing() {
        #expect(Lifetime(label: "keep") == .keep)
        #expect(Lifetime(label: "temporary") == .temporary)
        #expect(Lifetime(label: "8h") == .duration(28800))
        #expect(Lifetime(label: "7d") == .duration(604_800))
        #expect(Lifetime(label: "30m") == .duration(1800))
        #expect(Lifetime(label: "abc") == nil)
        #expect(Lifetime(label: "0h") == nil)
        #expect(Lifetime(label: "h") == nil)
    }

    @Test func shortestLifetimeWinsInCompose() {
        let key = Lifetime.labelKey
        func item(_ l: [String]) -> LeftoverItem? {
            let cs = l.enumerated().map { i, v in
                c("i\(i)", "s\(i)", labels: ["com.docker.compose.project": "p", key: v])
            }
            return LeftoverGrouper.group(cs, engine: "e", ignore: IgnoreRules()).items.first
        }
        #expect(item(["8h", "2h"])?.lifetime == .duration(7200))
        #expect(item(["8h", "temporary"])?.lifetime == .temporary)
        #expect(item(["keep", "temporary"])?.lifetime == .keep)
        #expect(item(["bogus"])?.lifetime == nil)
    }

    @Test func cleanupCommandsExactAndQuoted() {
        let cs = [
            c("a", "web", labels: ["com.docker.compose.project": "my app's"]),
            c("b", "it's", labels: [:]),
            c("k", "n'1", labels: ["io.x-k8s.kind.cluster": "c'l"]),
        ]
        let items = LeftoverGrouper.group(cs, engine: "orbstack", ignore: IgnoreRules()).items
        #expect(items[0].cleanup == ["docker --context 'orbstack' compose -p 'my app'\\''s' down"])
        #expect(items[1].cleanup == ["docker --context 'orbstack' rm -f 'b'"])
        #expect(items[2].cleanup == [
            "docker --context 'orbstack' stop 'n'\\''1'",
            "DOCKER_CONTEXT='orbstack' kind delete cluster --name 'c'\\''l'",
        ])
        for cmd in items.flatMap(\.cleanup) {
            #expect(!cmd.contains("prune"))
            #expect(!cmd.contains(" -v"))
        }
    }

    @Test func configDecodesWithDefaults() throws {
        let cfg = try JSONDecoder().decode(HeadroomConfig.self, from: Data(#"{"leftovers":{"ignore":{"names":["x*"]}}}"#.utf8))
        #expect(cfg.leftovers.afterMinutes == 60)
        #expect(cfg.leftovers.unownedAfterHours == 24)
        #expect(cfg.leftovers.ignore.names == ["x*"])
        #expect(cfg.leftovers.ignore.images.isEmpty)
    }
}
