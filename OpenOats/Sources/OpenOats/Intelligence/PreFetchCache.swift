import Foundation

/// Caches recent KB search results keyed by a normalized text fingerprint.
/// Thread-safe via actor isolation. Entries expire after a configurable TTL.
actor PreFetchCache {
    struct Entry: Sendable {
        let packs: [KBContextPack]
        let topScore: Double
        let createdAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttlSeconds: TimeInterval
    private let maxEntries: Int

    init(ttlSeconds: TimeInterval = 30, maxEntries: Int = 20) {
        self.ttlSeconds = ttlSeconds
        self.maxEntries = maxEntries
    }

    /// Store results for a text fingerprint.
    func store(fingerprint: String, packs: [KBContextPack]) {
        let topScore = packs.first?.score ?? 0
        entries[fingerprint] = Entry(packs: packs, topScore: topScore, createdAt: .now)
        evictStale()
    }

    /// Retrieve cached results if they exist and aren't stale.
    func get(fingerprint: String) -> Entry? {
        guard let entry = entries[fingerprint] else { return nil }
        if Date.now.timeIntervalSince(entry.createdAt) > ttlSeconds {
            entries.removeValue(forKey: fingerprint)
            return nil
        }
        return entry
    }

    /// The highest score across all non-stale entries.
    func bestScore() -> Double {
        evictStale()
        return entries.values.map(\.topScore).max() ?? 0
    }

    /// The best non-stale entry.
    func bestEntry() -> Entry? {
        evictStale()
        return entries.values.max(by: { $0.topScore < $1.topScore })
    }

    func clear() {
        entries.removeAll()
    }

    private func evictStale() {
        let cutoff = Date.now.addingTimeInterval(-ttlSeconds)
        for key in entries.keys where entries[key]!.createdAt <= cutoff {
            entries.removeValue(forKey: key)
        }
        if entries.count > maxEntries {
            let sorted = entries.sorted { $0.value.createdAt < $1.value.createdAt }
            for (key, _) in sorted.prefix(entries.count - maxEntries) {
                entries.removeValue(forKey: key)
            }
        }
    }

    /// Normalize text into a fingerprint for cache keying.
    /// Lowercases, strips non-alphanumerics, and takes the last ~50 words.
    static func fingerprint(_ text: String) -> String {
        TextSimilarity.normalizedWords(in: text).suffix(50).joined(separator: " ")
    }
}
