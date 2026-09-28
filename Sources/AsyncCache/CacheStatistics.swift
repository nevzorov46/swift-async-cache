/// What the cache has been doing. Useful in tests, and worth logging in an app:
/// a hit rate that never rises usually means the keys aren't what you think.
public struct CacheStatistics: Sendable, Equatable {
    /// Served from a value already in memory.
    public var hits = 0
    /// No value and no load in flight, so a load started.
    public var misses = 0
    /// Joined a load that was already running instead of starting a second one.
    public var coalesced = 0
    /// Dropped because the cache was full.
    public var evictions = 0
    /// Dropped because the value was older than its time to live.
    public var expirations = 0
    /// Loads that threw. Failures are never cached.
    public var failures = 0
    /// Loads cancelled because every caller waiting on them went away.
    public var cancellations = 0

    public init() {}

    /// Share of requests answered without starting a load, 0 … 1.
    public var hitRate: Double {
        let total = hits + misses + coalesced
        return total == 0 ? 0 : Double(hits + coalesced) / Double(total)
    }
}
