import Foundation
@testable import AsyncCache

enum TestError: Error, Equatable {
    case boom
}

/// A loader that only finishes when the test says so, and remembers what happened.
/// Nothing here sleeps: every test drives the timing itself.
actor GatedLoader: Loader {
    private(set) var calls = 0
    private(set) var cancellations = 0
    private var waiting: [CheckedContinuation<Void, Error>] = []

    func load(_ key: String) async throws -> Int {
        calls += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(continuation)
            }
        } onCancel: {
            Task { await self.noteCancellation() }
        }
        return key.count
    }

    /// Lets every in-flight load finish successfully.
    func release() {
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume() }
    }

    /// Fails every in-flight load.
    func fail(_ error: Error = TestError.boom) {
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    /// Spins until `calls` reaches `count`, so tests never guess at timing.
    func waitForCalls(_ count: Int) async {
        while calls < count { await Task.yield() }
    }

    private func noteCancellation() {
        cancellations += 1
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

/// A clock the test moves by hand, so time to live can be tested without waiting.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    // A plain lock rather than `Mutex`, which would need macOS 15 and so raise the
    // package's own minimum just to run the tests.
    private let lock = NSLock()
    private var instant = Instant(offset: .zero)

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    var minimumResolution: Duration { .zero }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // The cache never sleeps on the clock; it only reads `now`.
    }
}
