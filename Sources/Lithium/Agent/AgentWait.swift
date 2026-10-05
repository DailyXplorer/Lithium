import Foundation
import Observation

/// Waits on the browser's observed state (a tab's address, loading flag, commits, the tab list)
/// without polling: `check` runs again only when something it read changes. Cancelling the
/// task (Stop, the client cancelling) ends the wait with `CancellationError`.
@MainActor
enum AgentWait {
    /// The first value `check` returns, or nil once `deadline` passes. `check` throws to end
    /// the wait with an error (the tab closed under the agent, say).
    static func until<Value>(_ deadline: ContinuousClock.Instant, _ check: @escaping @MainActor () throws -> Value?) async throws -> Value? {
        while true {
            try Task.checkCancellation()
            let signal = Signal()
            let outcome = withObservationTracking {
                Result { try check() }
            } onChange: {
                Task { @MainActor in signal.fire() }
            }
            if let value = try outcome.get() { return value }
            guard ContinuousClock.now < deadline else { return nil }
            await signal.wait(until: deadline)
        }
    }

    /// One wake-up: whichever comes first of a change, the deadline, or cancellation.
    @MainActor
    private final class Signal {
        private var fired = false
        private var continuation: CheckedContinuation<Void, Never>?

        func fire() {
            fired = true
            continuation?.resume()
            continuation = nil
        }

        func wait(until deadline: ContinuousClock.Instant) async {
            let timer = Task { [weak self] in
                try? await Task.sleep(until: deadline)
                self?.fire()
            }
            defer { timer.cancel() }
            await withTaskCancellationHandler {
                guard !fired else { return }
                await withCheckedContinuation { continuation = $0 }
            } onCancel: {
                Task { @MainActor in self.fire() }
            }
        }
    }
}
