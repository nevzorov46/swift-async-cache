/// Keeps keys in order of use, most recent first, in O(1) per operation.
///
/// A dictionary of links instead of class nodes: same big-O as an intrusive
/// doubly linked list, no reference counting, and it stays a value type.
struct LRUOrder<Key: Hashable> {
    private struct Link {
        var newer: Key?
        var older: Key?
    }

    private var links: [Key: Link] = [:]
    private var newest: Key?
    private var oldest: Key?

    var count: Int { links.count }
    var leastRecentlyUsed: Key? { oldest }

    /// Moves an existing key to the front, or inserts it there.
    mutating func use(_ key: Key) {
        if links[key] != nil {
            guard newest != key else { return }
            detach(key)
        }
        links[key] = Link(newer: nil, older: newest)
        if let newest { links[newest]?.newer = key }
        newest = key
        if oldest == nil { oldest = key }
    }

    mutating func remove(_ key: Key) {
        guard links[key] != nil else { return }
        detach(key)
        links[key] = nil
    }

    mutating func removeAll() {
        links.removeAll()
        newest = nil
        oldest = nil
    }

    /// Unhooks a key from its neighbours, leaving its entry in place.
    private mutating func detach(_ key: Key) {
        guard let link = links[key] else { return }
        if let newer = link.newer { links[newer]?.older = link.older } else { newest = link.older }
        if let older = link.older { links[older]?.newer = link.newer } else { oldest = link.newer }
        links[key] = Link(newer: nil, older: nil)
    }
}
