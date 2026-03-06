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

private actor ItemProjector: Projector {
    let projectorId = "Items"
    let readModel: ReadModelStore

    init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    func apply(_ event: RecordedEvent) async throws {
        guard event.eventType == "ItemAdded" else { return }
        let envelope = try event.decode(TestEvent.self)
        guard case .itemAdded(let name) = envelope.event else { return }
        try await readModel.withConnection { conn -> Void in
            try conn.execute(
                "INSERT INTO items (name, stream) VALUES (\(param: name), \(param: event.streamName.description))"
            )
        }
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

    @Test func migrationsApplyIncrementally() async throws {
        let store = try ReadModelStore()
        nonisolated(unsafe) var callCount = 0

        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE migration_test_1 (id INTEGER)")
            callCount += 1
        }
        try await store.migrate()
        #expect(callCount == 1)

        // Register a second migration after the first migrate() call
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE migration_test_2 (id INTEGER)")
            callCount += 1
        }
        try await store.migrate()
        #expect(callCount == 2)

        // Migrate again — nothing new should run
        try await store.migrate()
        #expect(callCount == 2)
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

    @Test func rebuildProcessesMultipleBatches() async throws {
        let registry = EventTypeRegistry()
        registry.register(TestEvent.self, eventTypes: ["ItemAdded"])
        let eventStore = InMemoryEventStore(registry: registry)

        let meta = EventMetadata(traceId: "test")
        let stream = StreamName(category: "item", id: "1")
        for i in 1...5 {
            _ = try await eventStore.append(TestEvent.itemAdded(name: "Item\(i)"), to: stream, metadata: meta, expectedVersion: nil)
        }

        let readModel = try ReadModelStore()
        let projector = CountingProjector()
        try await readModel.rebuild(from: eventStore, projectors: [projector], batchSize: 2)

        let count = await projector.count
        #expect(count == 5)
    }

    @Test func rebuildWithNoEventsSucceeds() async throws {
        let eventStore = InMemoryEventStore()
        let readModel = try ReadModelStore()
        let projector = CountingProjector()
        try await readModel.rebuild(from: eventStore, projectors: [projector])

        let count = await projector.count
        #expect(count == 0)
    }

    // MARK: - Full Projection Cycle

    @Test func fullProjectionCycle() async throws {
        // Setup
        let registry = EventTypeRegistry()
        registry.register(TestEvent.self, eventTypes: ["ItemAdded"])
        let eventStore = InMemoryEventStore(registry: registry)
        let readModel = try ReadModelStore()

        await readModel.registerMigration { conn in
            try conn.execute("CREATE TABLE items (name VARCHAR, stream VARCHAR)")
        }
        try await readModel.migrate()

        let projector = ItemProjector(readModel: readModel)
        let pipeline = ProjectionPipeline()
        await pipeline.register(projector)

        let runTask = Task { await pipeline.run() }

        // Append and project
        let meta = EventMetadata(traceId: "test")
        let stream = StreamName(category: "item", id: "1")
        let recorded = try await eventStore.append(
            TestEvent.itemAdded(name: "Widget"),
            to: stream, metadata: meta, expectedVersion: nil
        )
        await pipeline.enqueue(recorded)
        try await pipeline.waitForIdle()

        // Query
        struct ItemRow: Decodable, Equatable {
            let name: String
            let stream: String
        }
        let items: [ItemRow] = try await readModel.query(ItemRow.self) {
            "SELECT name, stream FROM items"
        }
        #expect(items.count == 1)
        #expect(items[0] == ItemRow(name: "Widget", stream: "item-1"))

        // Cleanup
        await pipeline.stop()
        runTask.cancel()
    }

    // MARK: - Tiered Storage

    @Test func initWithDuckDBModeIsDefault() async throws {
        // Default init should work exactly as before
        let store = try ReadModelStore()
        let result = try await store.withConnection { conn in
            try conn.query("SELECT 42 AS value").scalarInt64()
        }
        #expect(result == 42)
    }

    @Test func registerTableTracksNames() async throws {
        let store = try ReadModelStore()
        await store.registerTable("orders")
        await store.registerTable("line_items")
        let tables = await store.registeredTables
        #expect(tables == ["orders", "line_items"])
    }

    // MARK: Cold Tier Mirrors & UNION ALL Views

    @Test func migrateCreatesColdMirrorsInTieredMode() async throws {
        let store = try await makeTieredStore()
        await store.registerTable("orders")
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE orders (id INTEGER, name VARCHAR, recorded_at TIMESTAMP)")
        }
        try await store.migrate()

        let coldCount = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM lake.orders").scalarInt64()
        }
        #expect(coldCount == 0)
    }

    @Test func migrateCreatesUnionViews() async throws {
        let store = try await makeTieredStore()
        await store.registerTable("orders")
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE orders (id INTEGER, name VARCHAR, recorded_at TIMESTAMP)")
        }
        try await store.migrate()

        try await store.withConnection { conn in
            try conn.execute("INSERT INTO orders VALUES (1, 'hot', CURRENT_TIMESTAMP)")
        }
        try await store.withConnection { conn in
            try conn.execute("INSERT INTO lake.orders VALUES (2, 'cold', CURRENT_TIMESTAMP)")
        }

        struct OrderRow: Decodable { let id: Int64; let name: String }
        let rows: [OrderRow] = try await store.query(OrderRow.self) {
            "SELECT id, name FROM v_orders ORDER BY id"
        }
        #expect(rows.count == 2)
        #expect(rows[0].name == "hot")
        #expect(rows[1].name == "cold")
    }

    @Test func migrateSkipsColdMirrorsInDuckDBMode() async throws {
        let store = try ReadModelStore()
        await store.registerTable("orders")
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE orders (id INTEGER, name VARCHAR, recorded_at TIMESTAMP)")
        }
        try await store.migrate()

        do {
            _ = try await store.withConnection { conn in
                try conn.query("SELECT COUNT(*) FROM v_orders").scalarInt64()
            }
            Issue.record("Expected query to fail — v_orders should not exist in duckdb mode")
        } catch {
            // Expected: table/view not found
        }
    }

    // MARK: Tiering Operations

    @Test func tierProjectionsMovesOldRows() async throws {
        let store = try await makeTieredStore()
        await store.registerTable("orders")
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE orders (id INTEGER, name VARCHAR, recorded_at TIMESTAMP)")
        }
        try await store.migrate()

        try await store.withConnection { conn in
            try conn.execute("INSERT INTO orders VALUES (1, 'old', TIMESTAMP '2020-01-01')")
            try conn.execute("INSERT INTO orders VALUES (2, 'recent', CURRENT_TIMESTAMP)")
        }

        let moved = try await store.tierProjections(olderThan: 365 * 5)
        #expect(moved == 1)

        let hotCount = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM orders").scalarInt64()
        }
        let coldCount = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM lake.orders").scalarInt64()
        }
        #expect(hotCount == 1)
        #expect(coldCount == 1)
    }

    @Test func tierProjectionsReturnsZeroInDuckDBMode() async throws {
        let store = try ReadModelStore()
        let moved = try await store.tierProjections(olderThan: 0)
        #expect(moved == 0)
    }

    @Test func tierProjectionsHandlesMultipleTables() async throws {
        let store = try await makeTieredStore()
        await store.registerTable("orders")
        await store.registerTable("line_items")
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE orders (id INTEGER, recorded_at TIMESTAMP)")
            try conn.execute("CREATE TABLE line_items (id INTEGER, recorded_at TIMESTAMP)")
        }
        try await store.migrate()

        try await store.withConnection { conn in
            try conn.execute("INSERT INTO orders VALUES (1, TIMESTAMP '2020-01-01')")
            try conn.execute("INSERT INTO line_items VALUES (1, TIMESTAMP '2020-01-01')")
            try conn.execute("INSERT INTO line_items VALUES (2, TIMESTAMP '2020-01-01')")
        }

        let moved = try await store.tierProjections(olderThan: 365)
        #expect(moved == 3)
    }

    @Test func viewSpansBothTiersAfterTiering() async throws {
        let store = try await makeTieredStore()
        await store.registerTable("orders")
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE orders (id INTEGER, name VARCHAR, recorded_at TIMESTAMP)")
        }
        try await store.migrate()

        try await store.withConnection { conn in
            try conn.execute("INSERT INTO orders VALUES (1, 'old', TIMESTAMP '2020-01-01')")
            try conn.execute("INSERT INTO orders VALUES (2, 'recent', CURRENT_TIMESTAMP)")
        }

        _ = try await store.tierProjections(olderThan: 365)

        struct OrderRow: Decodable { let id: Int64; let name: String }
        let rows: [OrderRow] = try await store.query(OrderRow.self) {
            "SELECT id, name FROM v_orders ORDER BY id"
        }
        #expect(rows.count == 2)
        #expect(rows[0].name == "old")
        #expect(rows[1].name == "recent")
    }

    // MARK: - S3 Configuration

    @Test func configureS3SetsAllFields() async throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()
        let s3Config = S3Config(
            region: "us-west-2",
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            endpoint: "localhost:9000",
            useSsl: false
        )
        try ReadModelStore.configureS3(connection: conn, s3Config: s3Config)

        let region = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_region'").scalarString()
        let keyId = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_access_key_id'").scalarString()
        let secret = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_secret_access_key'").scalarString()
        let endpoint = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_endpoint'").scalarString()
        let urlStyle = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_url_style'").scalarString()
        let useSsl = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_use_ssl'").scalarString()

        #expect(region == "us-west-2")
        #expect(keyId == "AKIAIOSFODNN7EXAMPLE")
        #expect(secret == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        #expect(endpoint == "localhost:9000")
        #expect(urlStyle == "path")
        #expect(useSsl == "false")
    }

    @Test func configureS3SkipsNilFields() async throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()

        // Capture defaults before configuring
        let defaultRegion = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_region'").scalarString()
        let defaultEndpoint = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_endpoint'").scalarString()

        let s3Config = S3Config(region: "eu-central-1")
        try ReadModelStore.configureS3(connection: conn, s3Config: s3Config)

        let region = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_region'").scalarString()
        let endpoint = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_endpoint'").scalarString()

        #expect(region == "eu-central-1")
        #expect(endpoint == defaultEndpoint, "Endpoint should remain at its default when not explicitly set")
        _ = defaultRegion  // Silence unused warning
    }

    @Test func configureS3DefaultsUseSslToTrue() async throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()
        let s3Config = S3Config(region: "ap-southeast-1")
        try ReadModelStore.configureS3(connection: conn, s3Config: s3Config)

        let useSsl = try conn.query("SELECT value FROM duckdb_settings() WHERE name = 's3_use_ssl'").scalarString()
        #expect(useSsl == "true", "useSsl defaults to true, so s3_use_ssl should remain true")
    }

    // MARK: - Full Tiered Cycle

    @Test func fullTieredProjectionCycle() async throws {
        let store = try await makeTieredStore()

        await store.registerTable("items")
        await store.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE items (
                    name VARCHAR,
                    stream VARCHAR,
                    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
        }
        try await store.migrate()

        // Write some "old" and "recent" data as a projector would
        try await store.withConnection { conn in
            try conn.execute("INSERT INTO items VALUES ('old-item', 'item-1', TIMESTAMP '2020-01-01')")
            try conn.execute("INSERT INTO items VALUES ('recent-item', 'item-2', CURRENT_TIMESTAMP)")
        }

        // Before tiering: hot has 2 rows, cold has 0
        let hotBefore = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM items").scalarInt64()
        }
        #expect(hotBefore == 2)

        // Tier old data
        let moved = try await store.tierProjections(olderThan: 365)
        #expect(moved == 1)

        // After tiering: hot has 1, cold has 1
        let hotAfter = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM items").scalarInt64()
        }
        let coldAfter = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM lake.items").scalarInt64()
        }
        #expect(hotAfter == 1)
        #expect(coldAfter == 1)

        // Query via view gets all data transparently
        struct ItemRow: Decodable, Equatable {
            let name: String
            let stream: String
        }
        let allItems: [ItemRow] = try await store.query(ItemRow.self) {
            "SELECT name, stream FROM v_items ORDER BY name"
        }
        #expect(allItems.count == 2)
        #expect(allItems[0] == ItemRow(name: "old-item", stream: "item-1"))
        #expect(allItems[1] == ItemRow(name: "recent-item", stream: "item-2"))

        // Hot-only query gets only recent data
        let hotItems: [ItemRow] = try await store.query(ItemRow.self) {
            "SELECT name, stream FROM items ORDER BY name"
        }
        #expect(hotItems.count == 1)
        #expect(hotItems[0] == ItemRow(name: "recent-item", stream: "item-2"))
    }
}
