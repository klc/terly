import XCTest
@testable import SSHConfigCore

/// WP8 perf guard: parsing and grouping a large, synthetic config must stay
/// well under a threshold generous enough to absorb CI-runner slowness/noise
/// (unlike a laptop, a shared CI VM can be several times slower and this test
/// only needs to catch a real algorithmic regression — e.g. an accidentally
/// quadratic grouping pass — not track micro-perf). This intentionally does
/// **not** use `measure { ... }`: `measure` reports/asserts against a
/// recorded local baseline, which doesn't travel with the repo and makes CI
/// noisy; a plain wall-clock diff against one fixed, generous threshold is
/// simpler and portable.
final class SSHConfigDocumentPerformanceTests: XCTestCase {
    /// 1000 hosts, each with a handful of directives and a hyphenated alias
    /// so they also exercise the multi-level `hostGroups` grouping (not just
    /// flat parsing) — e.g. `svc-web-42` groups under `svc → web`.
    private func makeSyntheticConfig(hostCount: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(hostCount * 6)
        let services = ["web", "api", "db", "cache", "worker"]
        let regions = ["ams", "fra", "iad", "sjc"]

        for index in 0 ..< hostCount {
            let service = services[index % services.count]
            let region = regions[index % regions.count]
            let alias = "\(region)-\(service)-\(index)"
            lines.append("Host \(alias)")
            lines.append("  HostName \(alias).internal.example.com")
            lines.append("  User deploy")
            lines.append("  Port 22")
            lines.append("  IdentityFile ~/.ssh/id_ed25519_\(region)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func testParsingAndGroupingOneThousandHostsCompletesWithinGenerousThreshold() {
        let source = makeSyntheticConfig(hostCount: 1000)
        // Generous on purpose: local runs finish in well under 100ms; 5s
        // leaves ~50x headroom for a slow/contended CI VM while still
        // failing hard on an accidental O(n^2)-or-worse regression.
        let thresholdSeconds: TimeInterval = 5

        let start = Date()
        let document = SSHConfigDocument(source: source)
        let hostBlockCount = document.hostBlocks.count
        let groups = document.hostGroups
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(hostBlockCount, 1000)
        XCTAssertFalse(groups.isEmpty)
        // Sanity: every host actually landed in the automatic prefix grouping
        // (region-service-index has 3 segments, so all 1000 hosts group).
        let groupedHostCount = groups.reduce(0) { $0 + totalHostCount(in: $1) }
        XCTAssertEqual(groupedHostCount, 1000)

        XCTAssertLessThan(
            elapsed,
            thresholdSeconds,
            "1000 host'luk config parse + gruplama \(thresholdSeconds)s eşiğini aştı (\(elapsed)s) — olası regresyon"
        )
    }

    private func totalHostCount(in group: SSHConfigHostGroup) -> Int {
        group.hosts.count + group.children.reduce(0) { $0 + totalHostCount(in: $1) }
    }
}
