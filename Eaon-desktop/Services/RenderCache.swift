import Foundation

/// Memoizes the expensive, pure text→value transforms the chat rerenders
/// constantly — syntax highlighting, markdown line parsing, inline
/// AttributedString building, diff-row derivation. SwiftUI views are
/// transient structs, so a computed property on a view re-runs its work on
/// EVERY body evaluation and every LazyVStack scroll-in; before this cache
/// existed, scrolling a conversation re-highlighted every visible code
/// block per frame, and a streaming reply re-did all of it per typewriter
/// tick (up to ~250/s) — measured live as a full core pinned for the whole
/// generation (94.8% CPU), which reads as "the app is laggy / hangs."
///
/// FIFO eviction, not true LRU — the workload is "same content re-rendered
/// many times, then never again" (a message's text is immutable once its
/// stream finishes), so recency tracking would buy nothing measurable.
/// Callers pass `store: false` for still-streaming content, whose key
/// changes every tick and would only churn the cache.
@MainActor
final class RenderCache {
    static let shared = RenderCache()

    private var storage: [String: Any] = [:]
    private var insertionOrder: [String] = []
    /// Entries, not bytes — the values are derived from message text the
    /// app already holds in memory anyway, so the practical ceiling is a
    /// few MB of AttributedStrings on top of what's already resident.
    private let capacity = 400

    private init() {}

    func value<T>(_ key: String, store: Bool = true, compute: () -> T) -> T {
        if let hit = storage[key] as? T { return hit }
        let computed = compute()
        guard store else { return computed }
        if storage[key] == nil { insertionOrder.append(key) }
        storage[key] = computed
        if insertionOrder.count > capacity {
            let overflow = insertionOrder.count - capacity
            for evicted in insertionOrder.prefix(overflow) {
                storage.removeValue(forKey: evicted)
            }
            insertionOrder.removeFirst(overflow)
        }
        return computed
    }
}
