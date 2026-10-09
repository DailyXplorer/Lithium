import Foundation
import Observation

/// Waits on observed state without polling: `check` runs again only when something it read changes.
@MainActor
enum AgentWait {
    /// The first non-nil value `check` returns, or nil once `deadline` passes.
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
