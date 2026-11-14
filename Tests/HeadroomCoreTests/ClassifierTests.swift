import Foundation
import Testing

@testable import HeadroomCore

struct ClassifierTests {
    static let me: UInt32 = 501

    func proc(_ pid: Int32, _ ppid: Int32, _ name: String, uid: UInt32 = ClassifierTests.me, path: String = "") -> ProcessIdentity {
        ProcessIdentity(key: ProcessKey(pid: pid, start: UInt64(pid)), ppid: ppid, uid: uid, name: name, path: path)
    }

    let classifier = Classifier(rules: .defaults, currentUID: ClassifierTests.me)

    @Test func ownRuleWins() {
        let procs = [proc(1, 0, "claude"), proc(2, 1, "go")]
        let out = classifier.classify(procs)
        #expect(out[procs[1].key] == .goBuilds)
        #expect(out[procs[0].key] == .agents)
    }

    @Test func nearestAncestorInherits() {
        let procs = [proc(1, 0, "claude"), proc(2, 1, "zsh"), proc(3, 2, "foo.test"), proc(4, 3, "kubectl")]
        let out = classifier.classify(procs)
        #expect(out[procs[3].key] == .goBuilds)
        #expect(out[procs[1].key] == .agents)
    }

    @Test func globSuffixPrefix() {
        let procs = [proc(1, 0, "pkg.test"), proc(2, 0, "qemu-system-aarch64"), proc(3, 0, "my.tester")]
        #expect(classifier.ownGroup(procs[0]) == .goBuilds)
        #expect(classifier.ownGroup(procs[1]) == .containers)
        #expect(classifier.ownGroup(procs[2]) == nil)
        #expect(Classifier.globMatches("*foo*", "xfoox"))
        #expect(!Classifier.globMatches("*foo*", "bar"))
    }

    @Test func matchingIsCaseSensitive() {
        #expect(classifier.ownGroup(proc(1, 0, "Claude")) == nil)
    }

    @Test func pathPrefixRules() {
        let vscode = proc(1, 0, "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        let other = proc(2, 0, "Electron", path: "/Applications/Other.app/Contents/MacOS/Electron")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agent = proc(3, 0, "node", path: home + "/.claude/local/node")
        #expect(classifier.ownGroup(vscode) == .ide)
        #expect(classifier.ownGroup(other) == nil)
        #expect(classifier.ownGroup(agent) == .agents)
    }

    @Test func otherUserUnclassifiedIsSystem() {
        let procs = [proc(1, 0, "launchd", uid: 0), proc(2, 1, "mdworker", uid: 0), proc(3, 0, "mystery")]
        let out = classifier.classify(procs)
        #expect(out[procs[1].key] == .system)
        #expect(out[procs[2].key] == .other)
    }

    @Test func missingParentAndCyclesTerminate() {
        let procs = [proc(5, 99, "a"), proc(6, 6, "b"), proc(7, 8, "c"), proc(8, 7, "d")]
        let out = classifier.classify(procs)
        #expect(out.count == 4)
        #expect(out.values.allSatisfy { $0 == .other })
    }

    @Test func fallbackIsNotInherited() {
        let parent = proc(1, 0, "launchd", uid: 0)
        let child = proc(2, 1, "mystery")
        for procs in [[parent, child], [child, parent]] {
            let out = classifier.classify(procs)
            #expect(out[parent.key] == .system)
            #expect(out[child.key] == .other)
        }
    }

    @Test func truncatedNameMatchesViaPath() {
        let vm = proc(
            1, 0, "com.apple.Virtualization.Virtua",
            path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine")
        #expect(classifier.ownGroup(vm) == .containers)
    }

    @Test func invalidRulesFileFallsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("groups-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[1,2".utf8).write(to: url)
        let (rules, warning) = GroupRules.load(from: url)
        #expect(rules.rules == GroupRules.defaults.rules)
        #expect(warning != nil)
        #expect(try Data(contentsOf: url) == Data("[1,2".utf8))
    }

    @Test func missingRulesFileWritesDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("groups.json")
        let (rules, warning) = GroupRules.load(from: url)
        #expect(warning == nil)
        #expect(rules == GroupRules.defaults)
        let decoded = try JSONDecoder().decode(GroupRules.self, from: Data(contentsOf: url))
        #expect(decoded == GroupRules.defaults)
    }

    @Test func reportFolding() {
        #expect(WorkloadGroup.browsers.reportGroup == .everydayApps)
        #expect(WorkloadGroup.communication.reportGroup == .everydayApps)
        #expect(WorkloadGroup.other.reportGroup == .everydayApps)
        #expect(WorkloadGroup.goBuilds.displayName == "Go builds & tests")
        #expect(ReportGroup.everydayApps.displayName == "Everyday apps")
    }
}
