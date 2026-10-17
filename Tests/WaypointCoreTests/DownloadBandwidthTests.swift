import Foundation
import Testing
@testable import WaypointCore

@Test func bandwidthBudgetCombinesTransfersAndDoesNotBankLongIdleTime() {
    var budget = BandwidthBudget(rate: 1_000, now: 0)
    budget.receive(600, at: 0)
    budget.receive(400, at: 0)
    budget.refill(at: 0.5)
    #expect(budget.mustWait)
    budget.refill(at: 1)
    #expect(!budget.mustWait)
    budget.refill(at: 100)
    budget.receive(1_000, at: 100)
    #expect(budget.mustWait)
    budget.setRate(2_000, at: 100)
    budget.refill(at: 100.45)
    #expect(!budget.mustWait)
    budget.receive(10_000, at: 100.45)
    #expect(budget.mustWait)
    budget.setRate(0, at: 100.45)
    #expect(!budget.mustWait)
}

@Test func speedLimitDefaultsToUnlimitedAndRemembersReadableChoices() throws {
    let suite = "waypoint-bandwidth-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DownloadSpeedLimit.load(from: defaults).label == "Unlimited")
    let limit = try #require(DownloadSpeedLimit.choices.first { $0.label == "5 MB/s" })
    limit.save(to: defaults)
    #expect(DownloadSpeedLimit.load(from: defaults).bytesPerSecond == 5_000_000)
    defaults.set(-99, forKey: DownloadSpeedLimit.defaultsKey)
    #expect(DownloadSpeedLimit.load(from: defaults).bytesPerSecond == 0)
}

@Test func bandwidthCapAppliesToConcurrentRealTransfersCombined() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let limiter = DownloadBandwidthLimiter(bytesPerSecond: 1_000_000)
    let client = server.client(["normal"], limiter: limiter)
    defer { client.session.invalidateAndCancel() }
    let clock = ContinuousClock(), start = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for key in ["aabb", "ccdd"] {
            group.addTask {
                let file = try await client.download(.data, key)
                defer { try? FileManager.default.removeItem(at: file) }
                #expect(try Data(contentsOf: file) == DownloadServer.payload)
            }
        }
        try await group.waitForAll()
    }
    let elapsed = start.duration(to: clock.now)
    // 4 MiB at 1 MB/s takes about 4.2 seconds across both connections.
    #expect(elapsed >= .seconds(3.2), "Combined transfers completed in \(elapsed)")
}

@Test func switchingToUnlimitedReleasesAnActiveTransferImmediately() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let limiter = DownloadBandwidthLimiter(bytesPerSecond: 250_000)
    let client = server.client(["normal"], limiter: limiter)
    defer { client.session.invalidateAndCancel() }
    let transfer = Task { try await client.download(.data, "aabb") }
    defer { transfer.cancel() }
    for _ in 0..<200 {
        if limiter.isWaitingForBandwidth { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(limiter.isWaitingForBandwidth)
    let start = ContinuousClock.now
    limiter.bytesPerSecond = 0
    let file = try await transfer.value
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(try Data(contentsOf: file) == DownloadServer.payload)
}

@Test func lowestBandwidthLimitIsSharedByEightArchiveRequests() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let client = server.client(["normal"], limiter: DownloadBandwidthLimiter(bytesPerSecond: 250_000))
    defer { client.session.invalidateAndCancel() }
    let start = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<8 {
            group.addTask {
                let lower = i * 128 * 1024, upper = (i + 1) * 128 * 1024 - 1
                let file = try await client.download(.data, "aabb", range: UInt64(lower)...UInt64(upper))
                defer { try? FileManager.default.removeItem(at: file) }
                #expect(try Data(contentsOf: file) == DownloadServer.payload[lower...upper])
            }
        }
        try await group.waitForAll()
    }
    #expect(start.duration(to: .now) >= .seconds(3.2))
    #expect(try server.requests().count == 8)
}

@Test @MainActor func pauseAlsoStopsATransferWaitingForBandwidth() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let limiter = DownloadBandwidthLimiter(bytesPerSecond: 250_000)
    let client = server.client(["normal"], limiter: limiter)
    defer { client.session.invalidateAndCancel() }
    let job = DownloadJob(uid: "limited-pause", category: .install) { _ in
        let file = try await client.download(.data, "aabb")
        try? FileManager.default.removeItem(at: file)
    }
    let run = Task { await job.run() }
    defer { job.pause() }
    for _ in 0..<200 {
        if limiter.isWaitingForBandwidth { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(limiter.isWaitingForBandwidth)
    let start = ContinuousClock.now
    job.pause()
    #expect(await run.value == .paused)
    #expect(start.duration(to: .now) < .seconds(1))
}
