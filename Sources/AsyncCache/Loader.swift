/// Where values come from when the cache doesn't have them.
///
/// A loader is anything that can turn a key into a value: a network request, a
/// database read, an expensive computation. The cache calls it at most once per
/// key, however many callers ask at the same time.
///
/// ```swift
/// struct AvatarLoader: Loader {
///     func load(_ id: User.ID) async throws -> Image {
///         try await api.avatar(for: id)
///     }
/// }
/// ```
public protocol Loader<Key, Value>: Sendable {
    associatedtype Key: Hashable & Sendable
    associatedtype Value: Sendable

    func load(_ key: Key) async throws -> Value
}
