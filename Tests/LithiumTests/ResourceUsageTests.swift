import Foundation
import Testing
@testable import Lithium

struct ResourceUsageTests {
    private let me = ProcessInfo.processInfo.processIdentifier

    /// The first sample has nothing to measure CPU against; the second does.
    @Test func samplesTheCurrentProcess() throws {
        var sampler = ResourceSampler()
        let firstSample = sampler.sample(me)
        let first = try #require(firstSample)
        #expect(first.footprint > 1_048_576)
        #expect(first.cpu == nil)
        let secondSample = sampler.sample(me)
        let second = try #require(secondSample)
        #expect(second.footprint > 1_048_576)
        #expect(second.cpu.map { $0 >= 0 } == true)
    }

    /// A busy thread reads as most of a core. Mach ticks left unconverted would read 2.4 % on
    /// Apple silicon.
    @Test func busyProcessReadsAsBusy() throws {
        var sampler = ResourceSampler()
        _ = sampler.sample(me)
        let end = Date().addingTimeInterval(0.3)
        var spins = 0
        while Date() < end { spins &+= 1 }
        let busy = sampler.sample(me)
        let cpu = try #require(busy?.cpu)
        #expect(cpu > 50)
        #expect(cpu < Double(ProcessInfo.processInfo.activeProcessorCount) * 100 + 50)
    }

    @Test func invalidProcessHasNoSample() {
        var sampler = ResourceSampler()
        let samples = [sampler.sample(0), sampler.sample(-1), sampler.sample(.max)]
        #expect(samples.allSatisfy { $0 == nil })
    }

    @Test func cpuIsTimeUsedOverTimePassed() {
        let start = ResourceSampler.Reading(cpuTime: 2_000_000_000, wallTime: 10_000_000_000)
        #expect(ResourceSampler.cpuPercent(from: start, to: .init(cpuTime: 2_040_000_000, wallTime: 11_000_000_000)) == 4)
        #expect(ResourceSampler.cpuPercent(from: start, to: .init(cpuTime: 3_500_000_000, wallTime: 11_000_000_000)) == 150)
        #expect(ResourceSampler.cpuPercent(from: start, to: .init(cpuTime: 2_040_000_000, wallTime: 10_000_000_000)) == nil)
        #expect(ResourceSampler.cpuPercent(from: start, to: .init(cpuTime: 1_000_000_000, wallTime: 11_000_000_000)) == nil)
    }

    @Test func memoryReadsLikeChrome() {
        #expect(UsageFormat.memory(312 * 1_048_576) == "312 MB")
        #expect(UsageFormat.memory(300_000) == "1 MB")
        #expect(UsageFormat.memory(1023 * 1_048_576) == "1023 MB")
        #expect(UsageFormat.memory(1_288_490_189) == "1.2 GB")
        #expect(UsageFormat.memory(3 * 1_073_741_824) == "3.0 GB")
    }

    @Test func cpuReadsAsWholePercent() {
        #expect(UsageFormat.cpu(0) == "< 1 %")
        #expect(UsageFormat.cpu(0.6) == "< 1 %")
        #expect(UsageFormat.cpu(1) == "1 %")
        #expect(UsageFormat.cpu(4.4) == "4 %")
        #expect(UsageFormat.cpu(150.6) == "151 %")
    }

    @Test func sharedProcessCountsTheOtherTabs() {
        #expect(TabUsage.sharing(10, among: [10, 11, nil, 10]) == 2)
        #expect(TabUsage.sharing(10, among: [11, nil]) == 0)
        #expect(TabUsage.sharing(10, among: []) == 0)
        #expect(UsageFormat.shared(with: 1) == "Shared with 1 other tab")
        #expect(UsageFormat.shared(with: 2) == "Shared with 2 other tabs")
    }
}

/// Real tabs in a whole Browser, which keeps its data in the home folder:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter ResourceUsage`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ResourceUsageLiveTests {
    @Test func awakeTabHasAMeasurableProcess() async throws {
        let browser = Browser()
        browser.commandWindow.regularTabs.forEach(browser.close)
        browser.newTab(url: URL(string: "data:text/html,<p>a")!)
        browser.newTab(url: URL(string: "data:text/html,<p>b")!)
        let tabs = browser.commandWindow.regularTabs
        #expect(tabs.count == 2)
        for _ in 0..<100 where tabs.contains(where: { $0.webProcessIdentifier == nil }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try #require(tabs[0].webProcessIdentifier)
        #expect(pid != ProcessInfo.processInfo.processIdentifier)
        var sampler = ResourceSampler()
        let first = sampler.sample(pid)
        #expect(try #require(first).footprint > 1_048_576)
        try await Task.sleep(for: .milliseconds(200))
        let second = sampler.sample(pid)
        #expect(second?.cpu.map { $0 >= 0 } == true)
    }
}
