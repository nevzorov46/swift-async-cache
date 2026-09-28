/// An async cache that loads each key at most once, however many callers ask at
/// the same time.
///
/// ```swift
/// let avatars = AsyncCache(loader: AvatarLoader(), capacity: 200, timeToLive: .seconds(300))
///
/// // Five cells appearing at once: one network request, five identical results.
/// async let a = avatars.value(for: id)
/// async let b = avatars.value(for: id)
/// ```
///
/// What it does beyond a dictionary of tasks:
///
/// - **One load per key.** Callers arriving while a load is in flight join it.
/// - **Failures are not cached.** A throwing load is dropped, so the next caller retries.
/// - **Cancellation is per caller.** Cancelling one caller resumes that caller with
///   `CancellationError` and leaves the load running for the others. When the last
///   caller goes away, the load itself is cancelled.
/// - **Bounded.** With a `capacity`, the least recently used value is evicted.
/// - **Expiring.** With a `timeToLive`, a stale value is dropped and reloaded on
///   the next request. The clock is injectable, so tests don't sleep.
public actor AsyncCache<L: Loader, C: Clock> where C.Duration == Duration {
    private enum Entry {
        case loading(Loading)
        case ready(Ready)
    }

    private struct Loading {
        let task: Task<L.Value, Error>
        var waiters: [Int: CheckedContinuation<L.Value, Error>] = [:]
    }

    private struct Ready {
        let value: L.Value
        let expires: C.Instant?
    }

    /// Values kept before the least recently used one is evicted. `nil` is unbounded.
    public let capacity: Int?
    /// How long a loaded value stays fresh. `nil` never expires.
    public let timeToLive: Duration?

    private let loader: L
    private let clock: C
    private var entries: [L.Key: Entry] = [:]
    private var order = LRUOrder<L.Key>()
    private var nextWaiterID = 0

    public private(set) var statistics = CacheStatistics()

    /// Values currently held in memory, loads in flight excluded.
    public var count: Int { order.count }

    public init(loader: L, capacity: Int? = nil, timeToLive: Duration? = nil, clock: C) {
        precondition(capacity.map { $0 > 0 } ?? true, "capacity must be positive")
        self.loader = loader
        self.capacity = capacity
        self.timeToLive = timeToLive
        self.clock = clock
    }

    /// The value for `key`, loading it if this is the first request for it.
    ///
    /// Throws whatever the loader throws, or `CancellationError` if this caller is
    /// cancelled while waiting.
    public func value(for key: L.Key) async throws -> L.Value {
        switch entries[key] {
        case .ready(let ready):
            if isFresh(ready) {
                statistics.hits += 1
                order.use(key)
                return ready.value
            }
            statistics.expirations += 1
            forget(key)
        case .loading:
            statistics.coalesced += 1
            return try await wait(for: key)
        case nil:
            break
        }
        statistics.misses += 1
        startLoad(of: key)
        return try await wait(for: key)
    }

    /// Starts a load without waiting for it - for lists that know what the user is
    /// about to scroll to. Does nothing if the value is already there or on its way.
    public func prefetch(_ key: L.Key) {
        switch entries[key] {
        case .ready(let ready) where isFresh(ready): return
        case .loading: return
        default: startLoad(of: key)
        }
    }

    /// Drops the value for `key`. A load already in flight is left alone: its
    /// callers still get their value, it just won't be cached.
    public func invalidate(_ key: L.Key) {
        guard case .ready = entries[key] else { return }
        forget(key)
    }

    public func removeAll() {
        entries = entries.filter { if case .loading = $0.value { return true } else { return false } }
        order.removeAll()
    }

    public func resetStatistics() {
        statistics = CacheStatistics()
    }

    // MARK: - Loading

    private func startLoad(of key: L.Key) {
        let loader = self.loader
        let task = Task { try await loader.load(key) }
        entries[key] = .loading(Loading(task: task))
        // A separate task carries the result back onto the actor, so that waiters
        // are resumed in one place whether they arrived before or after the load.
        Task { [weak self] in
            let result = await task.result
            await self?.finishLoad(of: key, with: result)
        }
    }

    private func wait(for key: L.Key) async throws -> L.Value {
        nextWaiterID += 1
        let id = nextWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation, id: id, key: key, alreadyCancelled: Task.isCancelled)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, key: key) }
        }
    }

    private func register(_ continuation: CheckedContinuation<L.Value, Error>, id: Int, key: L.Key,
                          alreadyCancelled: Bool) {
        // The handler can fire before this runs, so cancellation is checked here too;
        // otherwise a caller cancelled at the door would wait for a value forever.
        guard !alreadyCancelled else {
            continuation.resume(throwing: CancellationError())
            dropLoadIfUnwanted(key)
            return
        }
        guard case .loading(var loading) = entries[key] else {
            // The load finished while this caller was arriving.
            if case .ready(let ready) = entries[key], isFresh(ready) {
                continuation.resume(returning: ready.value)
            } else {
                continuation.resume(throwing: CancellationError())
            }
            return
        }
        loading.waiters[id] = continuation
        entries[key] = .loading(loading)
    }

    private func finishLoad(of key: L.Key, with result: Result<L.Value, Error>) {
        guard case .loading(let loading) = entries[key] else { return }
        switch result {
        case .success(let value):
            store(value, for: key)
            for continuation in loading.waiters.values { continuation.resume(returning: value) }
        case .failure(let error):
            // Failures are never cached: the next caller gets to try again.
            entries[key] = nil
            order.remove(key)
            statistics.failures += 1
            for continuation in loading.waiters.values { continuation.resume(throwing: error) }
        }
    }

    private func cancelWaiter(_ id: Int, key: L.Key) {
        guard case .loading(var loading) = entries[key],
              let continuation = loading.waiters.removeValue(forKey: id)
        else { return }
        continuation.resume(throwing: CancellationError())
        entries[key] = .loading(loading)
        dropLoadIfUnwanted(key)
    }

    /// Nobody is waiting for this load any more, so stop paying for it.
    private func dropLoadIfUnwanted(_ key: L.Key) {
        guard case .loading(let loading) = entries[key], loading.waiters.isEmpty else { return }
        loading.task.cancel()
        entries[key] = nil
        statistics.cancellations += 1
    }

    // MARK: - Storage

    private func store(_ value: L.Value, for key: L.Key) {
        entries[key] = .ready(Ready(value: value, expires: timeToLive.map { clock.now.advanced(by: $0) }))
        order.use(key)
        while let capacity, order.count > capacity, let victim = order.leastRecentlyUsed {
            forget(victim)
            statistics.evictions += 1
        }
    }

    private func isFresh(_ ready: Ready) -> Bool {
        guard let expires = ready.expires else { return true }
        return clock.now < expires
    }

    private func forget(_ key: L.Key) {
        entries[key] = nil
        order.remove(key)
    }
}

extension AsyncCache where C == ContinuousClock {
    /// A cache on the system clock.
    public init(loader: L, capacity: Int? = nil, timeToLive: Duration? = nil) {
        self.init(loader: loader, capacity: capacity, timeToLive: timeToLive, clock: ContinuousClock())
    }
}
