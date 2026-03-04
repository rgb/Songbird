import Songbird
import SongbirdTesting
import Testing
import Smew

@testable import SongbirdSmew

private struct Widget: Decodable, Equatable {
    let id: Int64
    let name: String
}

private enum TestEvent: Event, Equatable {
    case itemAdded(name: String)

    var eventType: String {
        switch self {
        case .itemAdded: "ItemAdded"
        }
    }
}

private actor CountingProjector: Projector {
    let projectorId = "Counting"
    private(set) var count = 0

    func apply(_ event: RecordedEvent) async throws {
        count += 1
    }
}

@Suite("ReadModelStore")
struct ReadModelStoreTests {

    @Test func initializesInMemory() async throws {
        let store = try ReadModelStore()
        let result = try await store.withConnection { conn in
            try conn.query("SELECT 42 AS value").scalarInt64()
        }
        #expect(result == 42)
    }

    @Test func withConnectionProvidesAccess() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE test (id INTEGER, name VARCHAR)")
            try conn.execute("INSERT INTO test VALUES (1, 'hello')")
        }
        let count = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM test").scalarInt64()
        }
        #expect(count == 1)
    }

    @Test func queryDecodesRows() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE widgets (id INTEGER, name VARCHAR)")
            try conn.execute("INSERT INTO widgets VALUES (1, 'Sprocket')")
            try conn.execute("INSERT INTO widgets VALUES (2, 'Gear')")
        }
        let widgets: [Widget] = try await store.query(Widget.self) {
            "SELECT id, name FROM widgets ORDER BY id"
        }
        #expect(widgets.count == 2)
        #expect(widgets[0] == Widget(id: 1, name: "Sprocket"))
        #expect(widgets[1] == Widget(id: 2, name: "Gear"))
    }

    @Test func queryFirstReturnsSingleRow() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE items (item_id INTEGER, item_name VARCHAR)")
            try conn.execute("INSERT INTO items VALUES (1, 'Alpha')")
        }
        struct Item: Decodable, Equatable {
            let itemId: Int64
            let itemName: String
        }
        let item: Item? = try await store.queryFirst(Item.self) {
            "SELECT item_id, item_name FROM items WHERE item_id = \(param: Int64(1))"
        }
        #expect(item == Item(itemId: 1, itemName: "Alpha"))
    }

    @Test func queryFirstReturnsNilWhenEmpty() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE empty_table (id INTEGER)")
        }
        struct Row: Decodable { let id: Int64 }
        let result: Row? = try await store.queryFirst(Row.self) {
            "SELECT id FROM empty_table"
        }
        #expect(result == nil)
    }

    // MARK: - Migrations

    @Test func migrateRunsPendingMigrations() async throws {
        let store = try ReadModelStore()
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE v1_table (id INTEGER)")
        }
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE v2_table (id INTEGER)")
        }
        try await store.migrate()

        let v1Count = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM v1_table").scalarInt64()
        }
        let v2Count = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM v2_table").scalarInt64()
        }
        #expect(v1Count == 0)
        #expect(v2Count == 0)
    }

    @Test func migrateSkipsAlreadyApplied() async throws {
        let store = try ReadModelStore()
        // Use nonisolated(unsafe) var because the migration closure captures it
        // and we need to track how many times it runs
        nonisolated(unsafe) var runCount = 0
        await store.registerMigration { conn in
            runCount += 1
            try conn.execute("CREATE TABLE m1 (id INTEGER)")
        }
        try await store.migrate()
        try await store.migrate()  // Second call should be a no-op
        #expect(runCount == 1)
    }

    @Test func migrateRunsInOrder() async throws {
        let store = try ReadModelStore()
        nonisolated(unsafe) var order: [Int] = []
        await store.registerMigration { _ in order.append(1) }
        await store.registerMigration { _ in order.append(2) }
        await store.registerMigration { _ in order.append(3) }
        try await store.migrate()
        #expect(order == [1, 2, 3])
    }

    // MARK: - Rebuild

    @Test func rebuildReplaysAllEvents() async throws {
        let registry = EventTypeRegistry()
        registry.register(TestEvent.self, eventTypes: ["ItemAdded"])
        let eventStore = InMemoryEventStore(registry: registry)

        let meta = EventMetadata(traceId: "test")
        let stream = StreamName(category: "item", id: "1")
        _ = try await eventStore.append(TestEvent.itemAdded(name: "A"), to: stream, metadata: meta, expectedVersion: nil)
        _ = try await eventStore.append(TestEvent.itemAdded(name: "B"), to: stream, metadata: meta, expectedVersion: nil)
        _ = try await eventStore.append(TestEvent.itemAdded(name: "C"), to: stream, metadata: meta, expectedVersion: nil)

        let readModel = try ReadModelStore()
        let projector = CountingProjector()
        try await readModel.rebuild(from: eventStore, projectors: [projector])

        let count = await projector.count
        #expect(count == 3)
    }

    @Test func rebuildWithNoEventsSucceeds() async throws {
        let eventStore = InMemoryEventStore()
        let readModel = try ReadModelStore()
        let projector = CountingProjector()
        try await readModel.rebuild(from: eventStore, projectors: [projector])

        let count = await projector.count
        #expect(count == 0)
    }
}
