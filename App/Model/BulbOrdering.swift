import Foundation
import GoveeLAN

/// The order the bulbs are arranged in: reading it, folding a rearrangement back into it,
/// and keeping it complete as bulbs are discovered.
///
/// The storage itself is `BulbNameStore`, which also holds the names. This is the policy
/// on top of it, kept out of `AppModel` so the rules about bulbs that are not on screen
/// live in one place with the reasons for them.
@MainActor
struct BulbOrdering {

    private let store: BulbNameStore

    init(store: BulbNameStore) {
        self.store = store
    }

    /// Known bulbs in the stored order, anything new after them by bulb id.
    func sorted(_ bulbs: [Bulb]) -> [Bulb] {
        store.sorted(bulbs)
    }

    var stored: [String] {
        store.order()
    }

    /// Adds ids the order has never seen, at the end. Nothing is ever removed: a bulb
    /// that is unplugged or has not answered a scan yet keeps its place for when it
    /// comes back.
    func noteDiscovered(_ ids: [String]) {
        let existing = store.order()
        let known = Set(existing)
        let newcomers = ids.filter { !known.contains($0) }
        guard !newcomers.isEmpty else { return }
        store.setOrder(existing + newcomers)
    }

    /// Writes a rearrangement of the bulbs that were on screen back into the order.
    ///
    /// A bulb that is unplugged is not in the list the user just dragged. Writing that
    /// list out as the whole order would forget where it belonged and it would come back
    /// at the bottom, so only the slots held by bulbs that were on screen are refilled,
    /// in the new order, and every other stored id keeps the slot it had.
    func apply(arrangement: [String]) {
        let existing = store.order()
        let onScreen = Set(arrangement)
        var remaining = arrangement[...]
        var result: [String] = []
        for id in existing {
            if onScreen.contains(id) {
                if let next = remaining.popFirst() { result.append(next) }
            } else {
                result.append(id)
            }
        }
        // Anything the stored order had no slot for, which is a bulb found since it was
        // last written, goes on the end.
        result.append(contentsOf: remaining)
        store.setOrder(result)
    }
}
