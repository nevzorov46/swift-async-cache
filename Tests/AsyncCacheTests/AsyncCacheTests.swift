import Testing
@testable import AsyncCache

@Suite("Coalescing")
struct CoalescingTests {
    @Test("five callers at once cause exactly one load")
    func oneLoadForManyCallers() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader)

        let results = Task {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<5 { group.addTask { try await cache.value(for: "hello") } }
                return try await group.reduce(into: [Int]()) { $0.append($1) }
            }
        }
        await waitUntil { await cache.statistics.misses + cache.statistics.coalesced == 5 }
        await loader.release()

        #expect(try await results.value == Array(repeating: 5, count: 5))
        #expect(await loader.calls == 1)
        #expect(await cache.statistics.misses == 1)
        #expect(await cache.statistics.coalesced == 4)
    }

    @Test("a loaded value is served from memory")
    func valueIsCached() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader)

        let first = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(1)
        await loader.release()
        _ = try await first.value

        #expect(try await cache.value(for: "hello") == 5)
        #expect(await loader.calls == 1)
        #expect(await cache.statistics.hits == 1)
    }

    @Test("a failed load is not cached")
    func failureIsNotCached() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader)

        let attempt = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(1)
        await loader.fail()
        await #expect(throws: TestError.boom) { try await attempt.value }
        #expect(await cache.count == 0)
        #expect(await cache.statistics.failures == 1)

        // the next caller gets a fresh attempt
        let retry = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(2)
        await loader.release()
        #expect(try await retry.value == 5)
    }

    @Test("prefetch warms the cache without a caller")
    func prefetchWarms() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader)

        await cache.prefetch("hello")
        await loader.waitForCalls(1)
        await loader.release()
        await waitUntil { await cache.count == 1 }

        #expect(try await cache.value(for: "hello") == 5)
        #expect(await loader.calls == 1)
        #expect(await cache.statistics.hits == 1)
    }
}

@Suite("Cancellation")
struct CancellationTests {
    @Test("cancelling one caller leaves the load running for the others")
    func oneCallerLeaves() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader)

        let leaving = Task { try await cache.value(for: "hello") }
        let staying = Task { try await cache.value(for: "hello") }
        await waitUntil { await cache.statistics.misses + cache.statistics.coalesced == 2 }

        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }

        await loader.release()
        #expect(try await staying.value == 5)
        #expect(await loader.calls == 1)
        #expect(await loader.cancellations == 0)
    }

    @Test("when the last caller goes away the load is cancelled")
    func lastCallerLeaves() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader)

        let only = Task { try await cache.value(for: "hello") }
        await waitUntil { await cache.statistics.misses == 1 }

        only.cancel()
        await #expect(throws: CancellationError.self) { try await only.value }
        await waitUntil { await loader.cancellations == 1 }

        #expect(await cache.count == 0)
        #expect(await cache.statistics.cancellations == 1)
    }
}

@Suite("Expiry and eviction")
struct LifetimeTests {
    @Test("a value past its time to live is reloaded")
    func valueExpires() async throws {
        let loader = GatedLoader()
        let clock = ManualClock()
        let cache = AsyncCache(loader: loader, timeToLive: .seconds(60), clock: clock)

        let first = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(1)
        await loader.release()
        _ = try await first.value

        clock.advance(by: .seconds(59))
        #expect(try await cache.value(for: "hello") == 5)
        #expect(await loader.calls == 1)

        clock.advance(by: .seconds(2))
        let reload = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(2)
        await loader.release()
        #expect(try await reload.value == 5)
        #expect(await cache.statistics.expirations == 1)
    }

    @Test("a full cache evicts the least recently used value")
    func evictsLeastRecentlyUsed() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader, capacity: 2)

        for key in ["one", "two"] {
            let task = Task { try await cache.value(for: key) }
            await loader.waitForCalls(await loader.calls + 1)
            await loader.release()
            _ = try await task.value
        }
        _ = try await cache.value(for: "one")   // "two" is now the least recently used

        let third = Task { try await cache.value(for: "three") }
        await loader.waitForCalls(3)
        await loader.release()
        _ = try await third.value

        #expect(await cache.count == 2)
        #expect(await cache.statistics.evictions == 1)

        // "one" is still there, "two" has to be loaded again
        #expect(try await cache.value(for: "one") == 3)
        #expect(await loader.calls == 3)
        let reload = Task { try await cache.value(for: "two") }
        await loader.waitForCalls(4)
        await loader.release()
        #expect(try await reload.value == 3)
    }

    @Test("invalidate drops one value, removeAll drops the rest")
    func manualEviction() async throws {
        let loader = GatedLoader()
        let cache = AsyncCache(loader: loader)

        for key in ["one", "two"] {
            let task = Task { try await cache.value(for: key) }
            await loader.waitForCalls(await loader.calls + 1)
            await loader.release()
            _ = try await task.value
        }
        #expect(await cache.count == 2)

        await cache.invalidate("one")
        #expect(await cache.count == 1)

        await cache.removeAll()
        #expect(await cache.count == 0)
    }
}

/// Spins until a condition holds. Every wait in these tests is on a state change,
/// never on a timer, so the suite is deterministic.
func waitUntil(_ condition: () async -> Bool) async {
    while await condition() == false { await Task.yield() }
}
