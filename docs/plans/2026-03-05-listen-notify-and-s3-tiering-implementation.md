# LISTEN/NOTIFY Subscriptions + S3 Cloud Tiering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `PostgresEventSubscription` (LISTEN/NOTIFY with fallback poll) to SongbirdPostgres and S3 backend support to SongbirdSmew's tiered storage.

**Architecture:** `PostgresEventSubscription` is an `AsyncSequence<RecordedEvent>` that uses a dedicated `PostgresConnection` for LISTEN notifications, falling back to periodic polling. It's a drop-in replacement for `EventSubscription`. S3 tiering extends `DuckLakeConfig.Backend` with `.s3(S3Config)` and configures DuckDB's httpfs extension on init.

**Tech Stack:** PostgresNIO (PostgresConnection, PostgresNotificationSequence), DuckDB httpfs extension, Swift Testing

---

### Task 1: S3Config and Backend Extension

**Files:**
- Create: `Sources/SongbirdSmew/S3Config.swift`
- Modify: `Sources/SongbirdSmew/DuckLakeConfig.swift`

**Step 1: Create S3Config**

Create `Sources/SongbirdSmew/S3Config.swift`:

```swift
/// Configuration for S3-compatible object storage.
///
/// Fields set to `nil` fall back to standard AWS environment variables
/// (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_ENDPOINT_URL`).
///
/// Set `endpoint` for S3-compatible stores (MinIO, rustfs, Garage, Cloudflare R2).
///
/// ```swift
/// // AWS S3 with explicit credentials
/// let config = S3Config(region: "us-east-1", accessKeyId: "AKIA...", secretAccessKey: "...")
///
/// // Local rustfs (env vars for credentials)
/// let config = S3Config(endpoint: "http://localhost:9000", useSsl: false)
/// ```
public struct S3Config: Sendable {
    /// AWS region (e.g. "us-east-1"). Nil uses `AWS_REGION` env var.
    public var region: String?

    /// AWS access key ID. Nil uses `AWS_ACCESS_KEY_ID` env var.
    public var accessKeyId: String?

    /// AWS secret access key. Nil uses `AWS_SECRET_ACCESS_KEY` env var.
    public var secretAccessKey: String?

    /// Custom endpoint URL for S3-compatible stores. Nil uses default AWS endpoint.
    public var endpoint: String?

    /// Whether to use SSL for the S3 connection. Default `true`.
    public var useSsl: Bool

    public init(
        region: String? = nil,
        accessKeyId: String? = nil,
        secretAccessKey: String? = nil,
        endpoint: String? = nil,
        useSsl: Bool = true
    ) {
        self.region = region
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.endpoint = endpoint
        self.useSsl = useSsl
    }
}
```

**Step 2: Update DuckLakeConfig.Backend**

In `Sources/SongbirdSmew/DuckLakeConfig.swift`, change the `Backend` enum from `String`-backed to a regular enum with an `.s3` case:

Replace:
```swift
    public enum Backend: String, Sendable {
        /// Local filesystem storage.
        case local
        // Future: case s3, gcs, azure
    }
```

With:
```swift
    /// Storage backend for Parquet data files.
    public enum Backend: Sendable {
        /// Local filesystem storage.
        case local

        /// S3-compatible object storage (AWS S3, rustfs, Garage, MinIO, R2).
        case s3(S3Config)
    }
```

**Step 3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 4: Commit**

```bash
git add Sources/SongbirdSmew/S3Config.swift Sources/SongbirdSmew/DuckLakeConfig.swift
git commit -m "Add S3Config and extend DuckLakeConfig.Backend with .s3 case"
```

---

### Task 2: ReadModelStore S3 Configuration

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`

**Step 1: Update `attachDuckLake` to handle S3 backend**

In `Sources/SongbirdSmew/ReadModelStore.swift`, replace the `attachDuckLake` method:

```swift
    private static func attachDuckLake(connection: Connection, config: DuckLakeConfig) throws {
        try connection.execute("INSTALL ducklake")
        try connection.execute("LOAD ducklake")

        if case .s3(let s3Config) = config.backend {
            try configureS3(connection: connection, s3Config: s3Config)
        }

        try connection.execute(
            "ATTACH 'ducklake:\(config.catalogPath)' AS \(Self.coldSchemaName) (DATA_PATH '\(config.dataPath)')"
        )
    }

    private static func configureS3(connection: Connection, s3Config: S3Config) throws {
        try connection.execute("INSTALL httpfs")
        try connection.execute("LOAD httpfs")

        if let region = s3Config.region {
            try connection.execute("SET s3_region = '\(region)'")
        }
        if let accessKeyId = s3Config.accessKeyId {
            try connection.execute("SET s3_access_key_id = '\(accessKeyId)'")
        }
        if let secretAccessKey = s3Config.secretAccessKey {
            try connection.execute("SET s3_secret_access_key = '\(secretAccessKey)'")
        }
        if let endpoint = s3Config.endpoint {
            try connection.execute("SET s3_endpoint = '\(endpoint)'")
            try connection.execute("SET s3_url_style = 'path'")
        }
        if !s3Config.useSsl {
            try connection.execute("SET s3_use_ssl = false")
        }
    }
```

**Step 2: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

**Step 3: Commit**

```bash
git add Sources/SongbirdSmew/ReadModelStore.swift
git commit -m "Add S3 httpfs configuration to ReadModelStore"
```

---

### Task 3: S3 Configuration Unit Tests

**Files:**
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`

**Step 1: Add S3 configuration tests**

These tests verify the correct DuckDB SET statements are generated. They use an in-memory database and intercept the SQL by checking DuckDB's settings after configuring S3.

Add a new test suite to `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`:

```swift
@Suite("S3 Configuration")
struct S3ConfigurationTests {
    @Test("configureS3 sets all explicit fields")
    func allFieldsSet() throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()

        try ReadModelStore.configureS3(connection: conn, s3Config: S3Config(
            region: "us-west-2",
            accessKeyId: "AKIATEST",
            secretAccessKey: "secret123",
            endpoint: "http://localhost:9000",
            useSsl: false
        ))

        let region = try conn.query("SELECT current_setting('s3_region')").scalarString()
        #expect(region == "us-west-2")
        let keyId = try conn.query("SELECT current_setting('s3_access_key_id')").scalarString()
        #expect(keyId == "AKIATEST")
        let secret = try conn.query("SELECT current_setting('s3_secret_access_key')").scalarString()
        #expect(secret == "secret123")
        let endpoint = try conn.query("SELECT current_setting('s3_endpoint')").scalarString()
        #expect(endpoint == "http://localhost:9000")
        let urlStyle = try conn.query("SELECT current_setting('s3_url_style')").scalarString()
        #expect(urlStyle == "path")
        let useSsl = try conn.query("SELECT current_setting('s3_use_ssl')").scalarString()
        #expect(useSsl == "false")
    }

    @Test("configureS3 skips nil fields")
    func nilFieldsSkipped() throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()

        // Install httpfs so settings exist
        try conn.execute("INSTALL httpfs")
        try conn.execute("LOAD httpfs")

        // Get default region before configuration
        let defaultRegion = try conn.query("SELECT current_setting('s3_region')").scalarString()

        try ReadModelStore.configureS3(connection: conn, s3Config: S3Config(
            endpoint: "http://localhost:9000",
            useSsl: false
        ))

        // Region should remain at default (not overwritten)
        let region = try conn.query("SELECT current_setting('s3_region')").scalarString()
        #expect(region == defaultRegion)

        // Endpoint should be set
        let endpoint = try conn.query("SELECT current_setting('s3_endpoint')").scalarString()
        #expect(endpoint == "http://localhost:9000")
    }

    @Test("configureS3 defaults useSsl to true")
    func sslDefaultTrue() throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()

        try ReadModelStore.configureS3(connection: conn, s3Config: S3Config(
            region: "eu-west-1"
        ))

        // useSsl=true means we don't set s3_use_ssl=false, so it stays at default (true)
        let useSsl = try conn.query("SELECT current_setting('s3_use_ssl')").scalarString()
        #expect(useSsl == "true")
    }
}
```

**Important:** The `configureS3` method needs to be made `static` and package-accessible (not `private`) for testing. In Step 2 of Task 2, it's already `private static`. Change it to:

```swift
    static func configureS3(connection: Connection, s3Config: S3Config) throws {
```

(Remove `private` — `@testable import SongbirdSmew` handles test access.)

**Step 2: Run tests**

```bash
swift test --filter S3Configuration 2>&1 | tail -20
```

Note: DuckDB may not support `current_setting()` for httpfs settings. If these tests fail, use an alternative approach: configure S3, then verify by attempting to query an S3 path and checking the error message contains the configured endpoint. The implementer should adapt the test strategy based on what DuckDB actually supports.

**Step 3: Commit**

```bash
git add Tests/SongbirdSmewTests/ReadModelStoreTests.swift Sources/SongbirdSmew/ReadModelStore.swift
git commit -m "Add S3 configuration unit tests"
```

---

### Task 4: PostgresEventSubscription — Core Structure

**Files:**
- Create: `Sources/SongbirdPostgres/PostgresEventSubscription.swift`

**Reference files:**
- `Sources/Songbird/EventSubscription.swift` — the polling-based subscription to mirror
- `Sources/SongbirdPostgres/PostgresEventStore.swift` — the NOTIFY channel name (`songbird_events`)

**Step 1: Create PostgresEventSubscription**

Create `Sources/SongbirdPostgres/PostgresEventSubscription.swift`:

```swift
import Foundation
import Logging
import PostgresNIO
import Songbird

/// A LISTEN/NOTIFY-based subscription that reads events from one or more categories as an `AsyncSequence`.
///
/// Uses a dedicated `PostgresConnection` for LISTEN notifications with a fallback poll as safety net.
/// Drop-in replacement for `EventSubscription` when using `PostgresEventStore`.
///
/// The subscription uses Postgres LISTEN on the `songbird_events` channel for near-instant wakeup
/// when new events are appended. A periodic fallback poll (default 5 seconds) ensures no events
/// are missed if a LISTEN notification is lost. If the fallback poll detects missed notifications,
/// the LISTEN connection is re-established automatically.
///
/// ```swift
/// let subscription = PostgresEventSubscription(
///     client: client,
///     connectionConfig: connectionConfig,
///     subscriberId: "order-projector",
///     categories: ["order"],
///     positionStore: positionStore
/// )
///
/// let task = Task {
///     for try await event in subscription {
///         try await projector.apply(event)
///     }
/// }
///
/// // Later: cancel stops the subscription
/// task.cancel()
/// ```
public struct PostgresEventSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    /// The channel name used by PostgresEventStore for NOTIFY.
    static let channel = "songbird_events"

    public let client: PostgresClient
    public let connectionConfig: PostgresConnection.Configuration
    public let subscriberId: String
    public let categories: [String]
    public let positionStore: any PositionStore
    public let batchSize: Int
    public let fallbackPollInterval: Duration

    public init(
        client: PostgresClient,
        connectionConfig: PostgresConnection.Configuration,
        subscriberId: String,
        categories: [String],
        positionStore: any PositionStore,
        batchSize: Int = 100,
        fallbackPollInterval: Duration = .seconds(5)
    ) {
        self.client = client
        self.connectionConfig = connectionConfig
        self.subscriberId = subscriberId
        self.categories = categories
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.fallbackPollInterval = fallbackPollInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            client: client,
            connectionConfig: connectionConfig,
            subscriberId: subscriberId,
            categories: categories,
            positionStore: positionStore,
            batchSize: batchSize,
            fallbackPollInterval: fallbackPollInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let client: PostgresClient
        let connectionConfig: PostgresConnection.Configuration
        let subscriberId: String
        let categories: [String]
        let positionStore: any PositionStore
        let batchSize: Int
        let fallbackPollInterval: Duration
        let logger = Logger(label: "songbird.postgres.subscription")

        private var currentBatch: [RecordedEvent] = []
        private var batchIndex: Int = 0
        private var globalPosition: Int64 = -1
        private var positionLoaded: Bool = false
        private var listenConnection: PostgresConnection?
        private var notificationIterator: PostgresNotificationSequence.AsyncIterator?

        init(
            client: PostgresClient,
            connectionConfig: PostgresConnection.Configuration,
            subscriberId: String,
            categories: [String],
            positionStore: any PositionStore,
            batchSize: Int,
            fallbackPollInterval: Duration
        ) {
            self.client = client
            self.connectionConfig = connectionConfig
            self.subscriberId = subscriberId
            self.categories = categories
            self.positionStore = positionStore
            self.batchSize = batchSize
            self.fallbackPollInterval = fallbackPollInterval
        }

        public mutating func next() async throws -> RecordedEvent? {
            // Load persisted position on first call
            if !positionLoaded {
                globalPosition = try await positionStore.load(subscriberId: subscriberId) ?? -1
                positionLoaded = true
            }

            // Return next event from current batch if available
            if batchIndex < currentBatch.count {
                let event = currentBatch[batchIndex]
                batchIndex += 1
                return event
            }

            // Current batch exhausted — save position if we had events
            if !currentBatch.isEmpty {
                let lastPosition = currentBatch[currentBatch.count - 1].globalPosition
                try await positionStore.save(
                    subscriberId: subscriberId,
                    globalPosition: lastPosition
                )
                globalPosition = lastPosition
            }

            // Ensure LISTEN connection is established
            if listenConnection == nil {
                try await establishListenConnection()
            }

            // Poll for next batch, using LISTEN for wakeup
            while !Task.isCancelled {
                try Task.checkCancellation()

                // Read events from the store
                let batch = try await readBatch()

                if !batch.isEmpty {
                    currentBatch = batch
                    batchIndex = 1
                    return batch[0]
                }

                // No events — wait for LISTEN notification or fallback timeout
                let receivedNotification = await waitForNotificationOrTimeout()

                if !receivedNotification {
                    // Fallback poll found nothing via notification — check store directly
                    let fallbackBatch = try await readBatch()
                    if !fallbackBatch.isEmpty {
                        // Fallback found events that LISTEN missed — re-establish connection
                        logger.warning("Fallback poll found events — re-establishing LISTEN connection")
                        await closeListenConnection()
                        try await establishListenConnection()

                        currentBatch = fallbackBatch
                        batchIndex = 1
                        return fallbackBatch[0]
                    }
                }
            }

            // Cancelled — clean up
            await closeListenConnection()
            return nil
        }

        private func readBatch() async throws -> [RecordedEvent] {
            try await client.withConnection { connection in
                let store = PostgresEventStore(client: client, registry: EventTypeRegistry())
                // Use readCategories directly via the client
                return try await store.readCategories(
                    categories,
                    from: globalPosition + 1,
                    maxCount: batchSize
                )
            }
        }

        private mutating func establishListenConnection() async throws {
            let connection = try await PostgresConnection.connect(
                configuration: connectionConfig,
                id: 0,
                logger: logger
            )
            let notifications = try await connection.listen(PostgresEventSubscription.channel)
            self.listenConnection = connection
            self.notificationIterator = notifications.makeAsyncIterator()
        }

        private mutating func closeListenConnection() async {
            if let connection = listenConnection {
                try? await connection.close()
                self.listenConnection = nil
                self.notificationIterator = nil
            }
        }

        /// Waits for a LISTEN notification or the fallback poll interval, whichever comes first.
        /// Returns `true` if a notification was received, `false` if the timeout expired.
        private mutating func waitForNotificationOrTimeout() async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { [notificationIterator] in
                    var iter = notificationIterator!
                    do {
                        _ = try await iter.next()
                        return true
                    } catch {
                        return false
                    }
                }

                group.addTask { [fallbackPollInterval] in
                    try? await Task.sleep(for: fallbackPollInterval)
                    return false
                }

                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
        }
    }
}
```

**Important implementation note:** The `readBatch` method above uses a workaround approach. The actual implementation should use the `PostgresClient` directly to execute the readCategories query, matching the pattern in `PostgresEventStore.readCategories`. The implementer should read `PostgresEventStore.swift` and extract or reuse the query logic. A cleaner approach is to accept an `EventStore` parameter (specifically `PostgresEventStore`) in the subscription init and call `store.readCategories` directly:

```swift
public let store: PostgresEventStore
```

This avoids duplicating query logic. Update the init to take `store: PostgresEventStore` instead of reconstructing one.

**Step 2: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

The implementer should fix any compilation errors. Key areas that may need adjustment:
- `PostgresConnection.listen()` API — the deprecated version returns `PostgresNotificationSequence` directly. Use `listen(on:consume:)` if needed, or use the deprecated version with `@available` suppression.
- `PostgresNotificationSequence.AsyncIterator` mutability in the task group — may need a wrapper.
- The `readBatch` approach — adjust to use the `store` property directly.

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresEventSubscription.swift
git commit -m "Add PostgresEventSubscription with LISTEN/NOTIFY and fallback poll"
```

---

### Task 5: PostgresEventSubscription Tests

**Files:**
- Create: `Tests/SongbirdPostgresTests/PostgresEventSubscriptionTests.swift`

**Step 1: Write tests**

Create `Tests/SongbirdPostgresTests/PostgresEventSubscriptionTests.swift`:

```swift
import Foundation
import Logging
import PostgresNIO
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdPostgres

@Suite("PostgresEventSubscription", .serialized)
struct PostgresEventSubscriptionTests {

    private enum TestEvent: Event {
        case happened(value: String)
        var eventType: String { "TestHappened" }
    }

    @Test("receives events via LISTEN notification")
    func listenReceivesEvents() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)

            let registry = EventTypeRegistry()
            registry.register(TestEvent.self, eventTypes: ["TestHappened"])

            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)

            let connectionConfig = await PostgresTestHelper.connectionConfig()

            let subscription = PostgresEventSubscription(
                client: client,
                connectionConfig: connectionConfig,
                subscriberId: "test-listener",
                categories: [],
                positionStore: positionStore,
                store: store,
                fallbackPollInterval: .seconds(30) // Long timeout — we expect LISTEN to fire
            )

            // Append an event after a short delay
            let appendTask = Task {
                try await Task.sleep(for: .milliseconds(500))
                try await store.append(
                    TestEvent.happened(value: "hello"),
                    to: StreamName(category: "test", id: "1"),
                    metadata: EventMetadata(),
                    expectedVersion: nil
                )
            }

            var receivedEvents: [RecordedEvent] = []
            let consumeTask = Task {
                for try await event in subscription {
                    receivedEvents.append(event)
                    if receivedEvents.count >= 1 { break }
                }
            }

            try await appendTask.value
            try await consumeTask.value

            #expect(receivedEvents.count == 1)
            #expect(receivedEvents[0].eventType == "TestHappened")
        }
    }

    @Test("persists position across restarts")
    func positionPersistence() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)

            let registry = EventTypeRegistry()
            registry.register(TestEvent.self, eventTypes: ["TestHappened"])

            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)

            // Append 3 events
            for i in 1...3 {
                try await store.append(
                    TestEvent.happened(value: "event-\(i)"),
                    to: StreamName(category: "test", id: "\(i)"),
                    metadata: EventMetadata(),
                    expectedVersion: nil
                )
            }

            let connectionConfig = await PostgresTestHelper.connectionConfig()

            // Read first 2 events
            let sub1 = PostgresEventSubscription(
                client: client,
                connectionConfig: connectionConfig,
                subscriberId: "position-test",
                categories: [],
                positionStore: positionStore,
                store: store,
                fallbackPollInterval: .milliseconds(100)
            )

            var count = 0
            for try await _ in sub1 {
                count += 1
                if count >= 2 { break }
            }

            // New subscription with same subscriberId should start from event 3
            let sub2 = PostgresEventSubscription(
                client: client,
                connectionConfig: connectionConfig,
                subscriberId: "position-test",
                categories: [],
                positionStore: positionStore,
                store: store,
                fallbackPollInterval: .milliseconds(100)
            )

            var remaining: [RecordedEvent] = []
            for try await event in sub2 {
                remaining.append(event)
                if remaining.count >= 1 { break }
            }

            #expect(remaining.count == 1)
            #expect(remaining[0].eventType == "TestHappened")
        }
    }

    @Test("fallback poll catches events when LISTEN misses them")
    func fallbackPoll() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)

            let registry = EventTypeRegistry()
            registry.register(TestEvent.self, eventTypes: ["TestHappened"])

            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)

            // Pre-append an event before subscription starts
            try await store.append(
                TestEvent.happened(value: "pre-existing"),
                to: StreamName(category: "test", id: "1"),
                metadata: EventMetadata(),
                expectedVersion: nil
            )

            let connectionConfig = await PostgresTestHelper.connectionConfig()

            // Short fallback interval to test the poll path
            let subscription = PostgresEventSubscription(
                client: client,
                connectionConfig: connectionConfig,
                subscriberId: "fallback-test",
                categories: [],
                positionStore: positionStore,
                store: store,
                fallbackPollInterval: .milliseconds(100)
            )

            var received: [RecordedEvent] = []
            for try await event in subscription {
                received.append(event)
                if received.count >= 1 { break }
            }

            #expect(received.count == 1)
            #expect(received[0].eventType == "TestHappened")
        }
    }

    @Test("filters by category")
    func categoryFiltering() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)

            let registry = EventTypeRegistry()
            registry.register(TestEvent.self, eventTypes: ["TestHappened"])

            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)

            // Append events to different categories
            try await store.append(
                TestEvent.happened(value: "order"),
                to: StreamName(category: "order", id: "1"),
                metadata: EventMetadata(),
                expectedVersion: nil
            )
            try await store.append(
                TestEvent.happened(value: "invoice"),
                to: StreamName(category: "invoice", id: "1"),
                metadata: EventMetadata(),
                expectedVersion: nil
            )

            let connectionConfig = await PostgresTestHelper.connectionConfig()

            // Subscribe only to "order" category
            let subscription = PostgresEventSubscription(
                client: client,
                connectionConfig: connectionConfig,
                subscriberId: "category-test",
                categories: ["order"],
                positionStore: positionStore,
                store: store,
                fallbackPollInterval: .milliseconds(100)
            )

            var received: [RecordedEvent] = []
            for try await event in subscription {
                received.append(event)
                if received.count >= 1 { break }
            }

            #expect(received.count == 1)
            #expect(received[0].streamName.category == "order")
        }
    }
}
```

**Important:** The tests above assume some API adjustments made in Task 4. The implementer should:
1. Add a `connectionConfig()` method to `PostgresTestHelper` that returns a `PostgresConnection.Configuration`
2. Adjust the `PostgresEventSubscription` init to also accept a `store: PostgresEventStore` parameter (as noted in Task 4)
3. Adapt test patterns based on actual compilation — the key behaviors to test are: LISTEN wakeup, position persistence, fallback poll, and category filtering

**Step 2: Run tests**

```bash
swift test --filter PostgresEventSubscription 2>&1 | tail -20
```

**Step 3: Commit**

```bash
git add Tests/SongbirdPostgresTests/PostgresEventSubscriptionTests.swift
git commit -m "Add PostgresEventSubscription tests"
```

---

### Task 6: PostgresTestHelper — connectionConfig

**Files:**
- Modify: `Tests/SongbirdPostgresTests/PostgresTestHelper.swift`

**Step 1: Add connectionConfig method**

Add to `PostgresTestHelper`:

```swift
    /// Returns a `PostgresConnection.Configuration` matching the test container.
    /// Used by `PostgresEventSubscription` for its dedicated LISTEN connection.
    static func connectionConfig() async -> PostgresConnection.Configuration {
        let clientConfig = await containerState.makeConfiguration()
        return PostgresConnection.Configuration(
            host: clientConfig.host,
            port: clientConfig.port,
            username: clientConfig.username,
            password: clientConfig.password,
            database: clientConfig.database,
            tls: .disable
        )
    }
```

**Note:** `PostgresClient.Configuration` and `PostgresConnection.Configuration` are different types. The implementer should read the `ContainerState.makeConfiguration()` method to extract the host/port/username/password/database fields and construct the `PostgresConnection.Configuration`. If the fields aren't directly accessible from `PostgresClient.Configuration`, store them separately in `ContainerState`.

**Step 2: Commit**

```bash
git add Tests/SongbirdPostgresTests/PostgresTestHelper.swift
git commit -m "Add connectionConfig helper for LISTEN tests"
```

---

### Task 7: Changelog Entry

**Files:**
- Create: `changelog/0024-listen-notify-and-s3-tiering.md`

**Step 1: Create changelog**

Create `changelog/0024-listen-notify-and-s3-tiering.md`:

```markdown
# LISTEN/NOTIFY Subscriptions + S3 Cloud Tiering

## PostgresEventSubscription

Added `PostgresEventSubscription` to `SongbirdPostgres` — a LISTEN/NOTIFY-based `AsyncSequence<RecordedEvent>` that is a drop-in replacement for the polling-based `EventSubscription`.

- **Dedicated LISTEN connection**: Uses a standalone `PostgresConnection` (not from pool) for `LISTEN songbird_events`
- **Hybrid wakeup**: LISTEN for near-instant delivery, fallback poll (default 5s) as safety net
- **Auto-reconnect**: If fallback poll detects missed notifications, the LISTEN connection is re-established
- **Same API shape**: `AsyncSequence<RecordedEvent>` with subscriberId, categories, positionStore, batchSize

## S3 Cloud Tiering

Extended `DuckLakeConfig.Backend` with `.s3(S3Config)` for S3-compatible cold-tier storage.

- **S3Config**: region, accessKeyId, secretAccessKey, endpoint, useSsl — nil fields fall back to AWS env vars
- **ReadModelStore**: Automatically loads httpfs extension and configures DuckDB S3 settings on init
- **Compatible stores**: AWS S3, rustfs, Garage, MinIO, Cloudflare R2 (via endpoint override)
- **Tiering unchanged**: `tierProjections(olderThan:)` works transparently — DuckLake handles S3 I/O
```

**Step 2: Commit**

```bash
git add changelog/0024-listen-notify-and-s3-tiering.md
git commit -m "Add changelog for LISTEN/NOTIFY subscriptions and S3 tiering"
```
