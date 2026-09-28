import Testing
@testable import AsyncCache

/// The comparison column in the README, as tests.
///
/// `NaiveCache` below is the dictionary-of-tasks cache that everyone writes. These
/// tests assert what it actually does, so the claims about it can be checked rather
/// than taken on trust - and so they stay true if the language changes underneath.
@Suite("What a dictionary of tasks does instead")
struct NaiveCacheTests {
    private actor NaiveCache {
        private var tasks: [String: Task<Int, Error>] = [:]
        private let loader: GatedLoader

        init(loader: GatedLoader) { self.loader = loader }

        func value(for key: String) async throws -> Int {
            if let task = tasks[key] { return try await task.value }
            let loader = self.loader
            let task = Task { try await loader.load(key) }
            tasks[key] = task
            return try await task.value
        }

        var entryCount: Int { tasks.count }
    }

    @Test("a cancelled caller waits for the whole load and takes the value anyway")
    func cancellationIsIgnored() async throws {
        let loader = GatedLoader()
        let cache = NaiveCache(loader: loader)

        let caller = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(1)
        caller.cancel()
        await loader.release()

        // `await task.value` is not a cancellation point, so the caller neither
        // throws nor returns early: it gets the value it no longer wants.
        #expect(try await caller.value == 5)
    }

    @Test("the load runs to completion even when no caller is left")
    func loadOutlivesItsCallers() async throws {
        let loader = GatedLoader()
        let cache = NaiveCache(loader: loader)

        let caller = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(1)
        caller.cancel()
        await loader.release()
        _ = try? await caller.value

        #expect(await loader.cancellations == 0)
    }

    @Test("a failed load is replayed for ever")
    func failureIsCached() async throws {
        let loader = GatedLoader()
        let cache = NaiveCache(loader: loader)

        let first = Task { try await cache.value(for: "hello") }
        await loader.waitForCalls(1)
        await loader.fail()
        await #expect(throws: TestError.boom) { try await first.value }

        // No second attempt is made: the failed task is still in the dictionary.
        await #expect(throws: TestError.boom) { try await cache.value(for: "hello") }
        #expect(await loader.calls == 1)
        #expect(await cache.entryCount == 1)
    }
}
