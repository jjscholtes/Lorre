import Foundation

/// Lets one processing job run at a time, in arrival order.
///
/// Sessions share the transcription and diarization services, which hold their
/// configuration and loaded models as actor state. Running two jobs at once would
/// let one job's configuration leak into the other and make them compete for the
/// Neural Engine, so jobs wait here first. A job cancelled while waiting leaves the
/// queue right away with a `CancellationError`.
actor ProcessingGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []

    /// Whether a job currently holds the gate.
    var isOccupied: Bool { isBusy }

    /// Number of jobs waiting behind the current one.
    var waitingCount: Int { waiters.count }

    func acquire() async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // Hand the gate straight to the next job; `isBusy` stays true.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
