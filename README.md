# swift-async-cache

An async cache that loads each key **at most once**, no matter how many callers ask at the same time - and gets cancellation right.

```swift
let avatars = AsyncCache(loader: AvatarLoader(), capacity: 200, timeToLive: .seconds(300))

// Five cells scroll into view at once: one network request, five identical results.
async let a = avatars.value(for: userID)
async let b = avatars.value(for: userID)
```

## The problem

Every codebase eventually grows this:

```swift
actor Cache<Key: Hashable, Value: Sendable> {
    private var tasks: [Key: Task<Value, Error>] = [:]

    func value(for key: Key) async throws -> Value {
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await load(key) }
        tasks[key] = task
        return try await task.value
    }
}
```

It coalesces requests, which is the point - and then it fails in four ways that only show up in production:

1. **One cancelled caller cancels everyone.** `try await task.value` propagates cancellation *into* the shared task. A cell scrolls off screen, the request dies, and the four other cells waiting on it get a `CancellationError` instead of an avatar.
2. **A failed load is cached forever.** The task stays in the dictionary holding its error, so every later caller replays the same failure. A single dropped packet poisons the key for the lifetime of the app.
3. **It grows without limit.** No capacity, no expiry - a cache that never forgets is a memory leak with good intentions.
4. **You can't test the expiry you eventually bolt on**, because it reads the wall clock.

This package is that actor with those four things fixed, plus tests that prove each one.

## Cancellation, precisely

Each caller waits on its own continuation instead of on the shared `Task`, so cancellation is per caller:

| What happens | What the cache does |
|---|---|
| One of several callers is cancelled | That caller throws `CancellationError` **immediately**. The load keeps running for the rest. |
| The **last** caller is cancelled | The load itself is cancelled, and the key is removed. Nothing is left running for nobody. |
| A caller is cancelled before it ever suspends | Still throws `CancellationError` - no waiting on a value that will never arrive. |
| The load throws | The entry is dropped, every waiter gets the error, and the next caller starts a fresh attempt. |

That middle row is the reason this exists: it needs the cache to know how many callers a load still has, which a `[Key: Task]` dictionary cannot know.

## Usage

```swift
import AsyncCache

struct AvatarLoader: Loader {
    let api: API

    func load(_ id: User.ID) async throws -> Image {
        try await api.avatar(for: id)
    }
}

let avatars = AsyncCache(
    loader: AvatarLoader(api: api),
    capacity: 200,             // least recently used values are evicted; nil is unbounded
    timeToLive: .seconds(300)  // nil never expires
)

let image = try await avatars.value(for: id)

await avatars.prefetch(nextID)    // start a load nobody is waiting for yet
await avatars.invalidate(id)      // drop one value
await avatars.removeAll()         // drop all of them
```

`prefetch` is the one to reach for in a `UICollectionViewDataSourcePrefetching` or `.task` on a row that's about to appear: it warms the key without a caller, and a real `value(for:)` arriving mid-flight joins that load instead of starting a second one.

### Deterministic tests

The clock is injected, so nothing in the test suite sleeps:

```swift
let clock = ManualClock()
let cache = AsyncCache(loader: loader, timeToLive: .seconds(60), clock: clock)

_ = try await cache.value(for: key)
clock.advance(by: .seconds(61))
_ = try await cache.value(for: key)   // loaded again, no waiting
```

Any `Clock` whose `Duration` is `Duration` works. The cache only ever reads `now` - it never sleeps on the clock itself.

### Statistics

```swift
let stats = await cache.statistics
print(stats.hitRate)     // 0 … 1
print(stats.coalesced)   // requests that joined a load in flight
```

`hits`, `misses`, `coalesced`, `evictions`, `expirations`, `failures`, `cancellations`. Worth logging: a hit rate that never rises usually means the keys aren't what you think they are.

## Design notes

- **`actor`, not a lock.** All mutable state lives on the actor. Every `await` inside it is treated as a suspension point where the world may have changed - the reentrancy bug in the naive version above is exactly a missing re-check after an `await`.
- **LRU order in O(1) without classes.** `LRUOrder` is a dictionary of `(newer, older)` links rather than a doubly linked list of nodes: same complexity, no reference counting, still a value type.
- **Failures are never cached.** If you want negative caching, cache a `Result` as your `Value`.
- **Swift 6 language mode**, strict concurrency, no `@unchecked Sendable` anywhere in the library.

## Non-goals

- **Not a disk cache.** Memory only. Persistence is a different problem with different failure modes; wrap this around your own store if you need one.
- **Not an image pipeline.** No decoding, resizing, or format handling - use [Nuke](https://github.com/kean/Nuke) for that.
- **No retry policy.** A failed load throws to its callers and is forgotten. Retrying is the caller's decision, and it belongs in the loader.
- **No cost-based eviction.** Capacity counts entries, not bytes. If you need bytes, `NSCache` already does that (and drops values whenever it likes).

## Requirements

Swift 6.0+ · macOS 14 · iOS 17 · tvOS 17 · watchOS 10 · visionOS 1 · Linux

## Installation

```swift
.package(url: "https://github.com/nevzorov46/swift-async-cache", from: "1.0.0")
```

```swift
.target(name: "YourTarget", dependencies: [.product(name: "AsyncCache", package: "swift-async-cache")])
```

## License

MIT - see [LICENSE](LICENSE).
