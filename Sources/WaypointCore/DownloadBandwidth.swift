import Foundation

public struct DownloadSpeedLimit: Equatable, Sendable {
    public static let defaultsKey = "downloadBytesPerSecond"
    public let bytesPerSecond: Int64
    public let label: String

    public static let choices: [Self] = [
        .init(bytesPerSecond: 250_000, label: "250 KB/s"),
        .init(bytesPerSecond: 500_000, label: "500 KB/s"),
        .init(bytesPerSecond: 1_000_000, label: "1 MB/s"),
        .init(bytesPerSecond: 2_000_000, label: "2 MB/s"),
        .init(bytesPerSecond: 3_000_000, label: "3 MB/s"),
        .init(bytesPerSecond: 5_000_000, label: "5 MB/s"),
        .init(bytesPerSecond: 10_000_000, label: "10 MB/s"),
        .init(bytesPerSecond: 20_000_000, label: "20 MB/s"),
        .init(bytesPerSecond: 50_000_000, label: "50 MB/s"),
        .init(bytesPerSecond: 100_000_000, label: "100 MB/s"),
        .init(bytesPerSecond: 0, label: "Unlimited"),
    ]

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        let value = Int64(defaults.integer(forKey: defaultsKey))
        return choices.first { $0.bytesPerSecond == value } ?? choices.last!
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(bytesPerSecond, forKey: Self.defaultsKey)
    }
}

/// A shared byte budget, including bytes already buffered by URLSession.
/// Debt carries across tasks, so concurrent/small downloads share the cap.
struct BandwidthBudget {
    private(set) var rate: Int64
    private(set) var balance: Double = 0
    private var updated: TimeInterval

    init(rate: Int64, now: TimeInterval) {
        self.rate = max(0, rate)
        updated = now
    }

    mutating func refill(at now: TimeInterval) {
        if rate > 0 { balance = min(Double(rate) * 0.1, balance + max(0, now - updated) * Double(rate)) }
        updated = now
    }

    mutating func receive(_ bytes: Int64, at now: TimeInterval) {
        refill(at: now)
        if rate > 0 { balance -= Double(max(0, bytes)) }
    }

    mutating func setRate(_ value: Int64, at now: TimeInterval) {
        refill(at: now)
        let value = max(0, value)
        if value == 0 || rate == 0 { balance = 0 }
        else { balance = min(balance, Double(value) * 0.1) }
        rate = value
    }

    var mustWait: Bool { rate > 0 && balance < 0 }
}

/// Suspends network tasks while the total received bytes exceed the budget.
/// URLSession can deliver some buffered data after suspend; it is charged too.
/// No timer runs when downloads are idle or the limit is Unlimited.
public final class DownloadBandwidthLimiter: @unchecked Sendable {
    public static let shared = DownloadBandwidthLimiter(bytesPerSecond: DownloadSpeedLimit.load().bytesPerSecond)

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.waypoint.download-bandwidth", qos: .utility)
    private var budget: BandwidthBudget
    private var suspended: [ObjectIdentifier: URLSessionTask] = [:]
    private var timer: DispatchSourceTimer?
    private static var now: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    public init(bytesPerSecond: Int64 = 0) {
        budget = BandwidthBudget(rate: bytesPerSecond, now: Self.now)
    }

    deinit { timer?.cancel() }

    var isWaitingForBandwidth: Bool {
        lock.withLock {
            budget.refill(at: Self.now)
            return budget.mustWait
        }
    }

    /// A final buffered chunk may finish despite suspend. Settle that debt
    /// before releasing the file or scheduling more work; cancellation still
    /// interrupts this wait immediately, and changing the limit takes effect.
    func waitUntilReady() async throws {
        while isWaitingForBandwidth { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
    }

    public var bytesPerSecond: Int64 {
        get { lock.withLock { budget.rate } }
        set {
            lock.withLock {
                guard newValue != budget.rate else { return }
                budget.setRate(newValue, at: Self.now)
                if !budget.mustWait { resumeLocked() }
            }
        }
    }

    func started(_ task: URLSessionTask) {
        lock.withLock {
            budget.refill(at: Self.now)
            if budget.mustWait { suspendLocked(task) }
        }
    }

    func received(_ bytes: Int64, from task: URLSessionTask) {
        lock.withLock {
            budget.receive(bytes, at: Self.now)
            if budget.mustWait { suspendLocked(task) }
        }
    }

    func finished(_ task: URLSessionTask) {
        lock.withLock {
            suspended.removeValue(forKey: ObjectIdentifier(task))
            if suspended.isEmpty { stopTimerLocked() }
        }
    }

    private func suspendLocked(_ task: URLSessionTask) {
        guard task.state != .completed, task.state != .canceling,
              suspended[ObjectIdentifier(task)] == nil else { return }
        task.suspend()
        suspended[ObjectIdentifier(task)] = task
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func tick() {
        lock.withLock {
            suspended = suspended.filter { $0.value.state != .completed && $0.value.state != .canceling }
            budget.refill(at: Self.now)
            if !budget.mustWait { resumeLocked() }
            else if suspended.isEmpty { stopTimerLocked() }
        }
    }

    private func resumeLocked() {
        let tasks = Array(suspended.values)
        suspended.removeAll()
        stopTimerLocked()
        for task in tasks where task.state != .completed && task.state != .canceling { task.resume() }
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }
}
