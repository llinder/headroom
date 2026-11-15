import Foundation
import Testing
@testable import HeadroomCore

@Suite struct DockerEnginesTests {
    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-docker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeContext(home: URL, id: String, name: String, host: String) throws {
        let dir = home.appendingPathComponent(".docker/contexts/meta/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"Name":"\#(name)","Endpoints":{"docker":{"Host":"\#(host)"}}}"#
        try json.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    private func resolved(_ url: URL) throws -> String {
        try #require(realpath(url.path, nil).map { String(cString: $0) })
    }

    @Test func discoversContextsAndDedupes() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sockA = home.appendingPathComponent("a.sock")
        let sockB = home.appendingPathComponent("b.sock")
        try touch(sockA)
        try touch(sockB)
        let link = home.appendingPathComponent("link.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sockA)
        try writeContext(home: home, id: "1", name: "alpha", host: "unix://\(sockA.path)")
        try writeContext(home: home, id: "2", name: "beta", host: "unix://\(link.path)")

        let engines = DockerEngines.discover(
            home: home,
            environment: ["DOCKER_HOST": "unix://\(sockB.path)"],
            systemSocket: home.appendingPathComponent("missing.sock").path)

        #expect(engines == [
            DockerEngine(context: "alpha", socketPath: try resolved(sockA)),
            DockerEngine(context: "env", socketPath: try resolved(sockB), dockerHost: "unix://\(try resolved(sockB))"),
        ])
    }

    @Test func orderIsContextsThenDefaultThenEnv() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = home.appendingPathComponent("ctx.sock")
        let sys = home.appendingPathComponent("sys.sock")
        let env = home.appendingPathComponent("env.sock")
        for s in [ctx, sys, env] { try touch(s) }
        try writeContext(home: home, id: "1", name: "zeta", host: "unix://\(ctx.path)")
        let engines = DockerEngines.discover(
            home: home, environment: ["DOCKER_HOST": "unix://\(env.path)"], systemSocket: sys.path)
        #expect(engines.map(\.context) == ["zeta", "default", "env"])
    }

    @Test func skipsNonUnixAndMissing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeContext(home: home, id: "1", name: "remote", host: "ssh://user@host")
        try writeContext(home: home, id: "2", name: "tcp", host: "tcp://127.0.0.1:2375")
        try writeContext(home: home, id: "3", name: "gone", host: "unix://\(home.path)/nope.sock")
        let engines = DockerEngines.discover(
            home: home,
            environment: ["DOCKER_HOST": "tcp://localhost:2375"],
            systemSocket: home.appendingPathComponent("none.sock").path)
        #expect(engines.isEmpty)
    }

    @Test func decodesContainerList() throws {
        let json = #"""
        [{"Id":"abc","Names":["/web","/alias"],"Image":"nginx:1","Labels":{"a":"b"},"State":"running"},
         {"Id":"def","Names":["/db"],"Image":"pg","Labels":null,"State":"exited"}]
        """#
        let list = try DockerContainer.decodeList(Data(json.utf8))
        #expect(list.count == 2)
        #expect(list[0].id == "abc")
        #expect(list[0].names == ["web", "alias"])
        #expect(list[0].image == "nginx:1")
        #expect(list[0].labels == ["a": "b"])
        #expect(list[0].state == "running")
        #expect(list[1].labels == [:])
        #expect(list[1].state == "exited")
    }

    @Test func parsesStartedAtFractional() throws {
        let json = #"{"State":{"StartedAt":"2026-11-14T10:00:00.123456789Z"}}"#
        let detail = try #require(ContainerDetail.parse(inspectJSON: Data(json.utf8)))
        #expect(abs(detail.startedAt - 1_794_650_400.123456789) < 0.001)
        let plain = try #require(ContainerDetail.parse(
            inspectJSON: Data(#"{"State":{"StartedAt":"2026-11-14T10:00:00Z"}}"#.utf8)))
        #expect(plain.startedAt == 1_794_650_400)
    }

    @Test func zeroStartedAtIsNil() {
        let json = #"{"State":{"StartedAt":"0001-01-01T00:00:00Z"}}"#
        #expect(ContainerDetail.parse(inspectJSON: Data(json.utf8)) == nil)
    }

    @Test func memoryEstimateSubtractsInactiveFile() {
        let v2 = #"{"memory_stats":{"usage":1000,"stats":{"inactive_file":300}}}"#
        #expect(ContainerDetail.memoryEstimate(statsJSON: Data(v2.utf8)) == 700)
        let v1 = #"{"memory_stats":{"usage":1000,"stats":{"total_inactive_file":400}}}"#
        #expect(ContainerDetail.memoryEstimate(statsJSON: Data(v1.utf8)) == 600)
        let over = #"{"memory_stats":{"usage":100,"stats":{"inactive_file":300}}}"#
        #expect(ContainerDetail.memoryEstimate(statsJSON: Data(over.utf8)) == 0)
        let none = #"{"memory_stats":{"usage":50}}"#
        #expect(ContainerDetail.memoryEstimate(statsJSON: Data(none.utf8)) == 50)
    }

    @Test func memoryEstimateMissingUsageIsNil() {
        #expect(ContainerDetail.memoryEstimate(statsJSON: Data(#"{"memory_stats":{}}"#.utf8)) == nil)
        #expect(ContainerDetail.memoryEstimate(statsJSON: Data("{}".utf8)) == nil)
    }
}
