import Foundation
import Testing
@testable import Lorre

private actor EventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

struct ProcessingGateTests {
    @Test
    func jobsRunOneAtATimeInArrivalOrder() async throws {
        let gate = ProcessingGate()
        let log = EventLog()

        try await gate.acquire()
        let second = Task {
            try await gate.acquire()
            await log.append("second")
            await gate.release()
        }
        while await gate.waitingCount < 1 { await Task.yield() }
        let third = Task {
            try await gate.acquire()
            await log.append("third")
            await gate.release()
        }
        while await gate.waitingCount < 2 { await Task.yield() }

        await log.append("first")
        await gate.release()
        try await second.value
        try await third.value

        #expect(await log.events == ["first", "second", "third"])
        #expect(await gate.isOccupied == false)
    }

    @Test
    func cancellingAQueuedJobRemovesItWithoutBlockingTheNext() async throws {
        let gate = ProcessingGate()
        try await gate.acquire()

        let cancelled = Task { try await gate.acquire() }
        while await gate.waitingCount < 1 { await Task.yield() }
        let next = Task {
            try await gate.acquire()
            await gate.release()
        }
        while await gate.waitingCount < 2 { await Task.yield() }

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await gate.waitingCount == 1)

        await gate.release()
        try await next.value
        #expect(await gate.isOccupied == false)
    }

    @Test
    func alreadyCancelledTaskDoesNotTakeTheGate() async throws {
        let gate = ProcessingGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.isOccupied == false)
    }
}
