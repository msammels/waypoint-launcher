import Foundation
import Observation

/// Owns one install/update task. Pausing cancels network requests and waits
/// for the installer to unwind before allowing another writer to start.
/// The operation retains its options and reuses staged/journaled data on run.
@MainActor
@Observable
public final class DownloadJob {
    public enum State: Equatable, Sendable {
        case ready, running, pausing, paused, completed
        case failed(String)
    }

    public typealias Progress = @Sendable (UpdateProgress) -> Void
    public typealias Operation = @Sendable (@escaping Progress) async throws -> Void

    public private(set) var state: State = .ready
    public private(set) var progress: UpdateProgress?
    public var canPause: Bool { state == .running }
    public var canResume: Bool {
        switch state {
        case .paused, .failed: task == nil
        default: false
        }
    }
    public var canCancel: Bool { state == .paused && task == nil }

    @ObservationIgnored private let uid: String
    @ObservationIgnored private let category: Diagnostics.Category
    @ObservationIgnored private let operation: Operation
    @ObservationIgnored private var task: Task<State, Never>?
    @ObservationIgnored private var generation = UUID()

    public init(uid: String, category: Diagnostics.Category, operation: @escaping Operation) {
        self.uid = uid
        self.category = category
        self.operation = operation
    }

    /// A second caller cannot start a duplicate task, including while pausing.
    @discardableResult
    public func run() async -> State {
        guard state == .ready || canResume else { return state }
        generation = UUID()
        let generation = generation
        state = .running
        let task = Task { [self] () -> State in
            let result: State
            do {
                try Task.checkCancellation()
                try await operation { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == generation,
                              self.state == .running || self.state == .pausing else { return }
                        self.progress = progress
                    }
                }
                // Finishing an already-started commit wins over a late pause.
                result = .completed
            } catch {
                if Task.isCancelled, state == .pausing, NetworkRetry.isCancellation(error) {
                    result = .paused
                    Log.notice(category, "paused", nil, ["uid": uid])
                } else {
                    result = .failed(errorMessage(error))
                    Log.error(category, "failed", nil, ["uid": uid, "error": error])
                }
            }
            self.task = nil
            state = result
            return result
        }
        self.task = task
        return await task.value
    }

    public func pause() {
        guard canPause, let task else { return }
        state = .pausing
        Log.info(category, "pause_requested", nil, ["uid": uid])
        task.cancel()
    }
}
