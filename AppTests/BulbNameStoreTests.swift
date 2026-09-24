import XCTest
import GoveeLAN
@testable import Glowbeat

final class BulbNameStoreTests: XCTestCase {

    private func makeStore() throws -> BulbNameStore {
        let name = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return BulbNameStore(defaults: defaults)
    }

    private func bulb(_ id: String) -> Bulb {
        Bulb(id: id, sku: "H6004", endpoint: LANEndpoint(host: "127.0.0.1", port: 4003))
    }

    func testAnUnnamedBulbUsesTheFallback() throws {
        let store = try makeStore()
        XCTAssertEqual(store.name(for: "AA:00", fallback: "Bulb 1"), "Bulb 1")
    }

    func testNamesRoundTripAndAreTrimmed() throws {
        let store = try makeStore()
        store.setName("  Kitchen  ", for: "AA:00")
        XCTAssertEqual(store.name(for: "AA:00", fallback: "Bulb 1"), "Kitchen")
    }

    func testAnEmptyNameClearsBackToTheFallback() throws {
        let store = try makeStore()
        store.setName("Kitchen", for: "AA:00")
        store.setName("   ", for: "AA:00")
        XCTAssertEqual(store.name(for: "AA:00", fallback: "Bulb 1"), "Bulb 1")
    }

    func testSortedUsesTheStoredOrderThenBulbIDForNewcomers() throws {
        let store = try makeStore()
        store.setOrder(["CC:22", "AA:00"])
        let sorted = store.sorted([bulb("AA:00"), bulb("BB:11"), bulb("CC:22")])
        XCTAssertEqual(sorted.map(\.id), ["CC:22", "AA:00", "BB:11"])
    }

    func testSortedFallsBackToBulbIDWhenNoOrderIsStored() throws {
        let store = try makeStore()
        let sorted = store.sorted([bulb("CC:22"), bulb("AA:00")])
        XCTAssertEqual(sorted.map(\.id), ["AA:00", "CC:22"])
    }
}
