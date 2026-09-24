import Foundation
import GoveeLAN

/// Bulb display names and ordering, keyed on the bulb id from the scan reply.
///
/// Govee's cloud names are not reachable without a login, so the app keeps its own.
final class BulbNameStore {

    private enum Key {
        static let names = "bulbNames"
        static let order = "bulbOrder"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func name(for bulbID: String, fallback: String) -> String {
        let stored = defaults.dictionary(forKey: Key.names) as? [String: String] ?? [:]
        guard let value = stored[bulbID], !value.isEmpty else { return fallback }
        return value
    }

    /// An empty or whitespace only name clears the entry so the fallback comes back.
    func setName(_ name: String, for bulbID: String) {
        var stored = defaults.dictionary(forKey: Key.names) as? [String: String] ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            stored[bulbID] = nil
        } else {
            stored[bulbID] = trimmed
        }
        defaults.set(stored, forKey: Key.names)
    }

    func order() -> [String] {
        defaults.stringArray(forKey: Key.order) ?? []
    }

    func setOrder(_ ids: [String]) {
        defaults.set(ids, forKey: Key.order)
    }

    /// Known bulbs come first in the stored order; anything new is appended by bulb id.
    func sorted(_ bulbs: [Bulb]) -> [Bulb] {
        let stored = order()
        let rank = Dictionary(stored.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return bulbs.sorted { left, right in
            switch (rank[left.id], rank[right.id]) {
            case let (leftRank?, rightRank?): return leftRank < rightRank
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.id < right.id
            }
        }
    }
}
