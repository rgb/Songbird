# SongbirdPostgres Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a `SongbirdPostgres` module providing PostgreSQL implementations of `EventStore`, `PositionStore`, and `SnapshotStore` using PostgresNIO, with Postgres-native features (JSONB, TIMESTAMPTZ, LISTEN/NOTIFY, UNIQUE constraint concurrency).

**Architecture:** Three struct-based store implementations sharing a caller-managed `PostgresClient`. Schema managed via `postgres-migrations`. All stores use PostgresNIO's string interpolation for parameterized queries. The `PostgresEventStore` uses `UNIQUE (stream_name, position)` for concurrency control and `NOTIFY songbird_events` after each append.

**Tech Stack:** PostgresNIO (>= 1.29.0), postgres-migrations (>= 1.1.0), Swift Testing, Docker (Postgres 16 for tests)

**Design doc:** `docs/plans/2026-03-05-songbird-postgres-design.md`

---

## Reference: Key PostgresNIO API Patterns

These patterns are used throughout the implementation tasks. Refer back here when implementing.

**Import and SPM:**
```swift
import PostgresNIO
// SPM: .product(name: "PostgresNIO", package: "postgres-nio")
```

**Client configuration:**
```swift
var config = PostgresClient.Configuration(
    host: "localhost", port: 5432,
    username: "songbird", password: "songbird",
    database: "songbird_test", tls: .disable
)
let client = PostgresClient(configuration: config)
```

**Parameterized queries via string interpolation:**
```swift
// \(value) creates a $N binding (safe, parameterized)
let rows = try await client.query("SELECT id FROM events WHERE stream_name = \(streamName)")
for try await (id,) in rows.decode((UUID,).self) { ... }
```

**Transactions:**
```swift
try await client.withTransaction { connection in
    try await connection.query("INSERT INTO ...")
}
```

**Unique constraint violation detection:**
```swift
do {
    try await client.query("INSERT INTO ...")
} catch let error as PSQLError {
    if error.serverInfo?[.sqlState] == "23505" {
        throw VersionConflictError(...)
    }
    throw error
}
```

**JSONB encoding:** Types conforming to `PostgresCodable` auto-encode. For raw JSON strings, use `PostgresQuery` string interpolation with the value as a `String` and cast to `::jsonb` in SQL.

**Row decoding:** Use tuple-based decoding:
```swift
for try await (col1, col2, col3) in rows.decode((String, Int64, UUID).self) { ... }
```

---

## Reference: Existing SQLite Implementations

The Postgres stores mirror the SQLite stores. Key files to reference:

- `Sources/SongbirdSQLite/SQLiteEventStore.swift` — Actor with `DispatchSerialQueue` executor, `db.transaction(.immediate)` for concurrency, SHA-256 hash chain, `verifyChain(batchSize:)`, `rawExecute` for test support
- `Sources/SongbirdSQLite/SQLitePositionStore.swift` — Actor, `positions` table, upsert
- `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift` — Actor, `snapshots` table with BLOB state, upsert
- `Sources/SongbirdSQLite/ChainVerificationResult.swift` — Struct with `intact`, `eventsVerified`, `brokenAtSequence`

Key differences for Postgres:
- **Structs, not actors** — `PostgresClient` manages connection pooling internally
- **JSONB** instead of TEXT for event data/metadata and JSONB instead of BLOB for snapshot state
- **TIMESTAMPTZ** instead of ISO8601 text strings for timestamps
- **BIGSERIAL** instead of INTEGER AUTOINCREMENT for global_position (still 1-based, subtract 1 for 0-based)
- **`UNIQUE (stream_name, position)`** constraint for optimistic concurrency (instead of `BEGIN IMMEDIATE` + manual version check)
- **`NOTIFY songbird_events`** after each append

---

### Task 1: Add SongbirdPostgres to Package.swift

**Files:**
- Modify: `Package.swift`

**Context:** Add the new module target and its dependencies. The module depends on `Songbird`, `PostgresNIO`, and `PostgresMigrations`. Also add a test target.

**Step 1: Add package dependencies**

Add these two lines to the `dependencies` array in `Package.swift`:

```swift
.package(url: "https://github.com/vapor/postgres-nio.git", from: "1.29.0"),
.package(url: "https://github.com/hummingbird-project/postgres-migrations.git", from: "1.1.0"),
```

**Step 2: Add the SongbirdPostgres target**

Add this target after the `SongbirdSQLite` target in the `targets` array:

```swift
// MARK: - Postgres

.target(
    name: "SongbirdPostgres",
    dependencies: [
        "Songbird",
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "PostgresMigrations", package: "postgres-migrations"),
    ]
),
```

**Step 3: Add the SongbirdPostgres product**

Add to the `products` array:

```swift
.library(name: "SongbirdPostgres", targets: ["SongbirdPostgres"]),
```

**Step 4: Add the test target**

Add after `SongbirdSQLiteTests`:

```swift
.testTarget(
    name: "SongbirdPostgresTests",
    dependencies: ["SongbirdPostgres", "SongbirdTesting"]
),
```

**Step 5: Create source and test directories with placeholder files**

```bash
mkdir -p Sources/SongbirdPostgres
mkdir -p Tests/SongbirdPostgresTests
```

Create `Sources/SongbirdPostgres/SongbirdPostgres.swift`:
```swift
// SongbirdPostgres — PostgreSQL event store, position store, and snapshot store implementations
```

Create `Tests/SongbirdPostgresTests/PostgresTestHelper.swift`:
```swift
// PostgresTestHelper — Test database setup/teardown for Postgres tests
```

**Step 6: Verify the build**

Run: `swift build`
Expected: Clean build with no warnings or errors.

**Step 7: Commit**

```bash
git add Package.swift Sources/SongbirdPostgres Tests/SongbirdPostgresTests
git commit -m "Add SongbirdPostgres module to Package.swift"
```

---

### Task 2: PostgresTestHelper

**Files:**
- Create: `Tests/SongbirdPostgresTests/PostgresTestHelper.swift`

**Context:** All Postgres tests need a running Postgres instance and a clean database. The helper creates a temporary test database, runs migrations, and provides a configured `PostgresClient`. Each test gets an isolated schema via a unique database name.

Because `PostgresClient` requires `client.run()` in a task group, the helper must manage the client lifecycle. Tests will use a pattern like:

```swift
try await PostgresTestHelper.withTestClient { client in
    let store = PostgresEventStore(client: client, registry: registry)
    // ... test code ...
}
```

**Step 1: Write the test helper**

Create `Tests/SongbirdPostgresTests/PostgresTestHelper.swift`:

```swift
import Foundation
import Logging
import PostgresNIO
@testable import SongbirdPostgres

enum PostgresTestHelper {
    /// Default test configuration — connects to localhost:5432 with songbird/songbird credentials.
    /// Override via environment variables: POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB.
    static func makeConfiguration(database: String? = nil) -> PostgresClient.Configuration {
        let host = ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432
        let username = ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "songbird"
        let password = ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "songbird"
        let db = database ?? ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "songbird_test"
        return PostgresClient.Configuration(
            host: host, port: port,
            username: username, password: password,
            database: db, tls: .disable
        )
    }

    /// Runs a test block with a connected PostgresClient that has migrations applied.
    /// The client is started in a background task and cancelled after the block completes.
    static func withTestClient(
        _ body: @Sendable (PostgresClient) async throws -> Void
    ) async throws {
        let logger = Logger(label: "songbird.test")
        let config = makeConfiguration()
        let client = PostgresClient(configuration: config)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            // Run migrations before test code
            try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

            // Run the test body
            try await body(client)

            // Cancel the client task
            group.cancelAll()
        }
    }

    /// Cleans all Songbird tables (events, subscriber_positions, snapshots) for test isolation.
    /// Call this at the start of each test to ensure a clean state.
    static func cleanTables(client: PostgresClient) async throws {
        try await client.query("TRUNCATE events RESTART IDENTITY CASCADE")
        try await client.query("TRUNCATE subscriber_positions")
        try await client.query("TRUNCATE snapshots")
    }
}
```

**Step 2: Verify it compiles (won't pass yet — SongbirdPostgresMigrations doesn't exist)**

This helper references `SongbirdPostgresMigrations` which will be created in Task 3. The file will compile after Task 3 is complete.

**Step 3: Commit**

```bash
git add Tests/SongbirdPostgresTests/PostgresTestHelper.swift
git commit -m "Add PostgresTestHelper for Postgres test database setup"
```

---

### Task 3: PostgresMigrations

**Files:**
- Create: `Sources/SongbirdPostgres/PostgresMigrations.swift`

**Context:** Schema management using `postgres-migrations` from the Hummingbird project. This creates all three tables (events, subscriber_positions, snapshots) via versioned migrations.

**Step 1: Write the migrations file**

Create `Sources/SongbirdPostgres/PostgresMigrations.swift`:

```swift
import Logging
import PostgresMigrations
import PostgresNIO

/// Registers and applies Songbird database migrations for PostgreSQL.
///
/// Usage:
/// ```swift
/// try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
/// ```
public enum SongbirdPostgresMigrations {
    /// Applies all Songbird migrations to the database.
    public static func apply(client: PostgresClient, logger: Logger) async throws {
        var migrations = PostgresMigrations()
        register(in: &migrations)
        try await migrations.apply(client: client, logger: logger, dryRun: false)
    }

    /// Registers all Songbird migrations without applying them.
    /// Useful if the caller wants to combine Songbird migrations with application-specific ones.
    public static func register(in migrations: inout PostgresMigrations) {
        migrations.add(CreateEventsTables())
    }
}

struct CreateEventsTables: DatabaseMigration {
    func apply(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS events (
                global_position  BIGSERIAL PRIMARY KEY,
                stream_name      TEXT NOT NULL,
                stream_category  TEXT NOT NULL,
                position         BIGINT NOT NULL,
                event_type       TEXT NOT NULL,
                data             JSONB NOT NULL,
                metadata         JSONB NOT NULL,
                event_id         UUID NOT NULL UNIQUE,
                timestamp        TIMESTAMPTZ NOT NULL,
                event_hash       TEXT,

                UNIQUE (stream_name, position)
            )
            """,
            logger: logger
        )
        try await connection.query(
            "CREATE INDEX IF NOT EXISTS idx_events_stream ON events(stream_name, position)",
            logger: logger
        )
        try await connection.query(
            "CREATE INDEX IF NOT EXISTS idx_events_category ON events(stream_category, global_position)",
            logger: logger
        )
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS subscriber_positions (
                subscriber_id    TEXT PRIMARY KEY,
                global_position  BIGINT NOT NULL,
                updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """,
            logger: logger
        )
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS snapshots (
                stream_name  TEXT PRIMARY KEY,
                state        JSONB NOT NULL,
                version      BIGINT NOT NULL,
                updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """,
            logger: logger
        )
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query("DROP TABLE IF EXISTS snapshots", logger: logger)
        try await connection.query("DROP TABLE IF EXISTS subscriber_positions", logger: logger)
        try await connection.query("DROP TABLE IF EXISTS events", logger: logger)
    }

    var name: String { "CreateEventsTables" }
    var group: DatabaseMigrationGroup { .default }
}
```

**Step 2: Verify it compiles**

Run: `swift build --target SongbirdPostgres`
Expected: Clean build. If `postgres-migrations` API differs from what's shown here, adjust to match the actual API (check the package's README/source).

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresMigrations.swift
git commit -m "Add PostgresMigrations for schema creation"
```

---

### Task 4: PostgresEventStore

**Files:**
- Create: `Sources/SongbirdPostgres/PostgresEventStore.swift`
- Remove placeholder: `Sources/SongbirdPostgres/SongbirdPostgres.swift`

**Context:** The main event store implementation. This is the most complex piece — it must conform to the `EventStore` protocol, use JSONB for data/metadata, TIMESTAMPTZ for timestamps, SHA-256 hash chain, `UNIQUE (stream_name, position)` for optimistic concurrency, and `NOTIFY songbird_events` after each append.

Key differences from SQLiteEventStore:
- **Struct** (not actor) — `PostgresClient` handles connection pooling
- Uses `client.withTransaction` for the append version-check-then-insert sequence
- Catches `PSQLError` with sqlState `"23505"` for unique constraint violations → `VersionConflictError`
- BIGSERIAL is 1-based; subtract 1 for 0-based global positions
- Timestamps are native `Date` ↔ `TIMESTAMPTZ` (PostgresNIO handles this natively)
- JSONB columns store event data and metadata as strings cast to jsonb

**Step 1: Write PostgresEventStore**

Create `Sources/SongbirdPostgres/PostgresEventStore.swift`:

```swift
import CryptoKit
import Foundation
import PostgresNIO
import Songbird

public enum PostgresEventStoreError: Error {
    case encodingFailed
}

public struct PostgresEventStore: EventStore, Sendable {
    private let client: PostgresClient
    private let registry: EventTypeRegistry

    public init(client: PostgresClient, registry: EventTypeRegistry) {
        self.client = client
        self.registry = registry
    }

    // MARK: - Append

    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        let streamStr = stream.description
        let category = stream.category
        let eventType = event.eventType
        let eventId = UUID()
        let now = Date()

        let eventData = try JSONEncoder().encode(event)
        guard let eventDataString = String(data: eventData, encoding: .utf8) else {
            throw PostgresEventStoreError.encodingFailed
        }
        let metadataData = try JSONEncoder().encode(metadata)
        guard let metadataString = String(data: metadataData, encoding: .utf8) else {
            throw PostgresEventStoreError.encodingFailed
        }

        let iso8601 = ISO8601DateFormatter().string(from: now)

        var globalPosition: Int64 = 0
        var position: Int64 = 0

        do {
            try await client.withTransaction { connection in
                // Version check
                let currentVersion = try await self.currentStreamVersion(connection: connection, streamName: streamStr)
                if let expected = expectedVersion, expected != currentVersion {
                    throw VersionConflictError(
                        streamName: stream,
                        expectedVersion: expected,
                        actualVersion: currentVersion
                    )
                }

                position = currentVersion + 1

                // Hash chain
                let previousHash = try await self.lastEventHash(connection: connection) ?? "genesis"
                let hashInput = "\(previousHash)\0\(eventType)\0\(streamStr)\0\(eventDataString)\0\(iso8601)"
                let eventHash = SHA256.hash(data: Data(hashInput.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()

                let rows = try await connection.query("""
                    INSERT INTO events (stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp, event_hash)
                    VALUES (\(streamStr), \(category), \(position), \(eventType), \(eventDataString)::jsonb, \(metadataString)::jsonb, \(eventId), \(now), \(eventHash))
                    RETURNING global_position
                    """,
                    logger: .init(label: "songbird.postgres")
                )
                for try await (gp,) in rows.decode((Int64,).self) {
                    globalPosition = gp - 1  // 0-based (BIGSERIAL starts at 1)
                }

                // Notify listeners
                try await connection.query(
                    "SELECT pg_notify('songbird_events', \(String(globalPosition)))",
                    logger: .init(label: "songbird.postgres")
                )
            }
        } catch let error as PSQLError {
            // Unique constraint violation on (stream_name, position) means a concurrent append
            if error.serverInfo?[.sqlState] == "23505" {
                let actualVersion = try await currentStreamVersion(streamName: streamStr)
                throw VersionConflictError(
                    streamName: stream,
                    expectedVersion: expectedVersion ?? -1,
                    actualVersion: actualVersion
                )
            }
            throw error
        }

        return RecordedEvent(
            id: eventId,
            streamName: stream,
            position: position,
            globalPosition: globalPosition,
            eventType: eventType,
            data: eventData,
            metadata: metadata,
            timestamp: now
        )
    }

    // MARK: - Read Stream

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let streamStr = stream.description
        let rows = try await client.query("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_name = \(streamStr) AND position >= \(position)
            ORDER BY position ASC
            LIMIT \(maxCount)
            """)

        var results: [RecordedEvent] = []
        for try await row in rows {
            results.append(try recordedEvent(from: row))
        }
        return results
    }

    // MARK: - Read Categories

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let adjustedPosition = globalPosition + 1  // Convert 0-based to 1-based BIGSERIAL

        let rows: PostgresRowSequence
        if categories.isEmpty {
            rows = try await client.query("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE global_position >= \(adjustedPosition)
                ORDER BY global_position ASC
                LIMIT \(maxCount)
                """)
        } else if categories.count == 1 {
            rows = try await client.query("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE stream_category = \(categories[0]) AND global_position >= \(adjustedPosition)
                ORDER BY global_position ASC
                LIMIT \(maxCount)
                """)
        } else {
            // For multiple categories, build an ANY($1) query
            rows = try await client.query("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE stream_category = ANY(\(categories)) AND global_position >= \(adjustedPosition)
                ORDER BY global_position ASC
                LIMIT \(maxCount)
                """)
        }

        var results: [RecordedEvent] = []
        for try await row in rows {
            results.append(try recordedEvent(from: row))
        }
        return results
    }

    // MARK: - Read Last Event

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        let streamStr = stream.description
        let rows = try await client.query("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_name = \(streamStr)
            ORDER BY position DESC
            LIMIT 1
            """)

        for try await row in rows {
            return try recordedEvent(from: row)
        }
        return nil
    }

    // MARK: - Stream Version

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        try await currentStreamVersion(streamName: stream.description)
    }

    // MARK: - Chain Verification

    public func verifyChain(batchSize: Int = 1000) async throws -> ChainVerificationResult {
        var previousHash = "genesis"
        var verified = 0
        var offset = 0

        while true {
            let rows = try await client.query("""
                SELECT global_position, event_type, stream_name, data::text, to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), event_hash
                FROM events
                ORDER BY global_position ASC
                LIMIT \(batchSize) OFFSET \(offset)
                """)

            var batchCount = 0
            for try await (globalPos, eventType, streamName, dataStr, timestamp, storedHash)
                in rows.decode((Int64, String, String, String, String, String?).self)
            {
                batchCount += 1

                let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(dataStr)\0\(timestamp)"
                let computedHash = SHA256.hash(data: Data(hashInput.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()

                if let storedHash, storedHash != computedHash {
                    return ChainVerificationResult(
                        intact: false,
                        eventsVerified: verified,
                        brokenAtSequence: globalPos
                    )
                }

                previousHash = storedHash ?? computedHash
                verified += 1
            }

            if batchCount < batchSize { break }
            offset += batchSize

            await Task.yield()
        }

        return ChainVerificationResult(intact: true, eventsVerified: verified)
    }

    // MARK: - Test Support

    /// Execute raw SQL. Intended for test scenarios (e.g., corrupting data to test chain verification).
    public func rawExecute(_ sql: String) async throws {
        try await client.query(PostgresQuery(unsafeSQL: sql))
    }

    // MARK: - Private Helpers

    private func currentStreamVersion(streamName: String) async throws -> Int64 {
        try await currentStreamVersion(connection: nil, streamName: streamName)
    }

    private func currentStreamVersion(connection: PostgresConnection? = nil, streamName: String) async throws -> Int64 {
        let rows: PostgresRowSequence
        if let connection {
            rows = try await connection.query(
                "SELECT MAX(position) FROM events WHERE stream_name = \(streamName)",
                logger: .init(label: "songbird.postgres")
            )
        } else {
            rows = try await client.query(
                "SELECT MAX(position) FROM events WHERE stream_name = \(streamName)"
            )
        }

        for try await (maxPos,) in rows.decode((Int64?,).self) {
            if let maxPos { return maxPos }
        }
        return -1
    }

    private func lastEventHash(connection: PostgresConnection) async throws -> String? {
        let rows = try await connection.query(
            "SELECT event_hash FROM events ORDER BY global_position DESC LIMIT 1",
            logger: .init(label: "songbird.postgres")
        )

        for try await (hash,) in rows.decode((String?,).self) {
            return hash
        }
        return nil
    }

    private func recordedEvent(from row: PostgresRandomAccessRow) throws -> RecordedEvent {
        let autoincPos = try row.decode(Int64.self, context: .default, file: #file, line: #line)
        let globalPosition = autoincPos - 1  // 0-based

        // Decode using column indices
        let columns = row
        var cells = columns.makeIterator()

        // We need random access decoding. Let's use the column-based approach.
        let gp = try row[data: 0].decode(Int64.self, context: .default)
        let streamStr = try row[data: 1].decode(String.self, context: .default)
        let category = try row[data: 2].decode(String.self, context: .default)
        let position = try row[data: 3].decode(Int64.self, context: .default)
        let eventType = try row[data: 4].decode(String.self, context: .default)
        let dataStr = try row[data: 5].decode(String.self, context: .default)
        let metadataStr = try row[data: 6].decode(String.self, context: .default)
        let eventId = try row[data: 7].decode(UUID.self, context: .default)
        let timestamp = try row[data: 8].decode(Date.self, context: .default)

        let stream = StreamName(category: category, id: extractId(from: streamStr, category: category))
        let eventData = Data(dataStr.utf8)
        let metadata = try JSONDecoder().decode(EventMetadata.self, from: Data(metadataStr.utf8))

        return RecordedEvent(
            id: eventId,
            streamName: stream,
            position: position,
            globalPosition: gp - 1,
            eventType: eventType,
            data: eventData,
            metadata: metadata,
            timestamp: timestamp
        )
    }

    private func extractId(from streamName: String, category: String) -> String? {
        let prefix = category + "-"
        if streamName.hasPrefix(prefix) && streamName.count > prefix.count {
            return String(streamName.dropFirst(prefix.count))
        }
        return nil
    }
}
```

**Important implementation notes:**
- The `recordedEvent(from:)` method uses `PostgresRandomAccessRow` for column-based decoding. The exact API may differ from what's shown here — check PostgresNIO's actual row access API and adjust accordingly. An alternative is to use tuple-based decoding directly in the query methods (like `for try await (gp, stream, ...) in rows.decode((Int64, String, ...).self)`).
- The hash chain verification formats timestamps via `to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')` to produce ISO8601 strings matching the format used during append (via `ISO8601DateFormatter`). This ensures the hash computed during verification matches the hash computed during append.
- The `rawExecute` method uses `PostgresQuery(unsafeSQL:)` for unparameterized SQL — only for test support.
- When the PostgresNIO `query()` or `withTransaction()` APIs differ from what's shown, adapt the implementation to match the actual API. The key patterns are correct; exact method signatures may need adjusting.

**Step 2: Delete the placeholder file**

Delete `Sources/SongbirdPostgres/SongbirdPostgres.swift`.

**Step 3: Verify it compiles**

Run: `swift build --target SongbirdPostgres`
Expected: Clean build. Fix any PostgresNIO API mismatches.

**Step 4: Commit**

```bash
git add Sources/SongbirdPostgres/
git commit -m "Add PostgresEventStore with full EventStore conformance"
```

---

### Task 5: PostgresPositionStore

**Files:**
- Create: `Sources/SongbirdPostgres/PostgresPositionStore.swift`

**Context:** Simple struct conforming to `PositionStore`. Two methods: `load` and `save` with upsert semantics.

**Step 1: Write PostgresPositionStore**

Create `Sources/SongbirdPostgres/PostgresPositionStore.swift`:

```swift
import Foundation
import PostgresNIO
import Songbird

public struct PostgresPositionStore: PositionStore, Sendable {
    private let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func load(subscriberId: String) async throws -> Int64? {
        let rows = try await client.query(
            "SELECT global_position FROM subscriber_positions WHERE subscriber_id = \(subscriberId)"
        )
        for try await (position,) in rows.decode((Int64,).self) {
            return position
        }
        return nil
    }

    public func save(subscriberId: String, globalPosition: Int64) async throws {
        try await client.query("""
            INSERT INTO subscriber_positions (subscriber_id, global_position, updated_at)
            VALUES (\(subscriberId), \(globalPosition), NOW())
            ON CONFLICT (subscriber_id) DO UPDATE SET
                global_position = EXCLUDED.global_position,
                updated_at = NOW()
            """)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build --target SongbirdPostgres`
Expected: Clean build.

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresPositionStore.swift
git commit -m "Add PostgresPositionStore with PositionStore conformance"
```

---

### Task 6: PostgresSnapshotStore

**Files:**
- Create: `Sources/SongbirdPostgres/PostgresSnapshotStore.swift`

**Context:** Struct conforming to `SnapshotStore`. Stores snapshot state as JSONB (since aggregate state is JSON-encoded). Uses upsert for save.

**Step 1: Write PostgresSnapshotStore**

Create `Sources/SongbirdPostgres/PostgresSnapshotStore.swift`:

```swift
import Foundation
import PostgresNIO
import Songbird

public struct PostgresSnapshotStore: SnapshotStore, Sendable {
    private let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func saveData(
        _ data: Data,
        version: Int64,
        for stream: StreamName
    ) async throws {
        let streamStr = stream.description
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw PostgresEventStoreError.encodingFailed
        }
        try await client.query("""
            INSERT INTO snapshots (stream_name, state, version, updated_at)
            VALUES (\(streamStr), \(jsonString)::jsonb, \(version), NOW())
            ON CONFLICT (stream_name) DO UPDATE SET
                state = EXCLUDED.state,
                version = EXCLUDED.version,
                updated_at = NOW()
            """)
    }

    public func loadData(
        for stream: StreamName
    ) async throws -> (data: Data, version: Int64)? {
        let streamStr = stream.description
        let rows = try await client.query(
            "SELECT state::text, version FROM snapshots WHERE stream_name = \(streamStr) LIMIT 1"
        )
        for try await (stateStr, version) in rows.decode((String, Int64).self) {
            let data = Data(stateStr.utf8)
            return (data, version)
        }
        return nil
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build --target SongbirdPostgres`
Expected: Clean build.

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresSnapshotStore.swift
git commit -m "Add PostgresSnapshotStore with SnapshotStore conformance"
```

---

### Task 7: PostgresEventStore Tests

**Files:**
- Create: `Tests/SongbirdPostgresTests/PostgresEventStoreTests.swift`

**Context:** Mirror all 20 tests from `SQLiteEventStoreTests`. These tests require a running Postgres instance on localhost:5432 with a `songbird_test` database. Use `PostgresTestHelper` for setup.

**Prerequisites:** A running Postgres instance. Start one with Docker:
```bash
docker run -d --name songbird-postgres -e POSTGRES_USER=songbird -e POSTGRES_PASSWORD=songbird -e POSTGRES_DB=songbird_test -p 5432:5432 postgres:16
```

**Step 1: Write the event store tests**

Create `Tests/SongbirdPostgresTests/PostgresEventStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres
@testable import SongbirdTesting

enum PGAccountEvent: Event {
    case credited(amount: Int)
    case debited(amount: Int, note: String)

    var eventType: String {
        switch self {
        case .credited: "Credited"
        case .debited: "Debited"
        }
    }
}

@Suite("PostgresEventStore")
struct PostgresEventStoreTests {
    let stream = StreamName(category: "account", id: "abc")

    func makeRegistry() -> EventTypeRegistry {
        let registry = EventTypeRegistry()
        registry.register(PGAccountEvent.self, eventTypes: ["Credited", "Debited"])
        return registry
    }

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let recorded = try await store.append(
                PGAccountEvent.credited(amount: 100),
                to: stream,
                metadata: EventMetadata(traceId: "t1"),
                expectedVersion: nil
            )
            #expect(recorded.streamName == stream)
            #expect(recorded.position == 0)
            #expect(recorded.globalPosition == 0)
            #expect(recorded.eventType == "Credited")
            #expect(recorded.metadata.traceId == "t1")
        }
    }

    @Test func appendIncrementsPositions() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let r1 = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            let r2 = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            #expect(r1.position == 0)
            #expect(r1.globalPosition == 0)
            #expect(r2.position == 1)
            #expect(r2.globalPosition == 1)
        }
    }

    @Test func appendToMultipleStreams() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "account", id: "b")
            let r1 = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            let r2 = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            #expect(r1.position == 0)
            #expect(r2.position == 0)
            #expect(r1.globalPosition == 0)
            #expect(r2.globalPosition == 1)
        }
    }

    @Test func appendedDataIsDecodable() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let recorded = try await store.append(PGAccountEvent.credited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            let envelope = try recorded.decode(PGAccountEvent.self)
            #expect(envelope.event == .credited(amount: 42))
        }
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            let r2 = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
            #expect(r2.position == 1)
        }
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            await #expect(throws: VersionConflictError.self) {
                _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
            }
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            await #expect(throws: VersionConflictError.self) {
                _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
            }
        }
    }

    // MARK: - Read Stream

    @Test func readStreamReturnsEventsInOrder() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.debited(amount: 50, note: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readStream(stream, from: 0, maxCount: 100)
            #expect(events.count == 3)
            #expect(events[0].position == 0)
            #expect(events[1].position == 1)
            #expect(events[2].position == 2)
            #expect(events[0].eventType == "Credited")
            #expect(events[2].eventType == "Debited")
        }
    }

    @Test func readStreamFromPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readStream(stream, from: 1, maxCount: 100)
            #expect(events.count == 2)
            #expect(events[0].position == 1)
        }
    }

    @Test func readStreamWithMaxCount() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            for i in 0..<10 {
                _ = try await store.append(PGAccountEvent.credited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            }
            let events = try await store.readStream(stream, from: 0, maxCount: 3)
            #expect(events.count == 3)
        }
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
            #expect(events.isEmpty)
        }
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "account", id: "b")
            let s3 = StreamName(category: "other", id: "c")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategory("account", from: 0, maxCount: 100)
            #expect(events.count == 2)
        }
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "account", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategory("account", from: 1, maxCount: 100)
            #expect(events.count == 1)
            #expect(events[0].globalPosition == 1)
        }
    }

    // MARK: - Read Last / Version

    @Test func readLastEvent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let last = try await store.readLastEvent(in: stream)
            #expect(last != nil)
            #expect(last!.position == 1)
        }
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let last = try await store.readLastEvent(in: stream)
            #expect(last == nil)
        }
    }

    @Test func streamVersionReturnsLatestPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let version = try await store.streamVersion(stream)
            #expect(version == 1)
        }
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let version = try await store.streamVersion(stream)
            #expect(version == -1)
        }
    }

    // MARK: - Multi-Category Reads

    @Test func readCategoriesWithMultipleCategories() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            let s3 = StreamName(category: "order", id: "c")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategories(["account", "invoice"], from: 0, maxCount: 100)
            #expect(events.count == 2)
            #expect(events[0].streamName == s1)
            #expect(events[1].streamName == s2)
        }
    }

    @Test func readAllReturnsAllCategories() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            let s3 = StreamName(category: "order", id: "c")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readAll(from: 0, maxCount: 100)
            #expect(events.count == 3)
        }
    }

    @Test func readAllFromGlobalPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readAll(from: 1, maxCount: 100)
            #expect(events.count == 1)
            #expect(events[0].globalPosition == 1)
        }
    }

    @Test func readCategoriesWithEmptyArrayReturnsAllEvents() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategories([], from: 0, maxCount: 100)
            #expect(events.count == 2)
        }
    }

    @Test func readCategoryConvenienceStillWorks() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "other", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategory("account", from: 0, maxCount: 100)
            #expect(events.count == 1)
            #expect(events[0].streamName == s1)
        }
    }
}
```

**Step 2: Run the tests**

First ensure Postgres is running:
```bash
docker run -d --name songbird-postgres -e POSTGRES_USER=songbird -e POSTGRES_PASSWORD=songbird -e POSTGRES_DB=songbird_test -p 5432:5432 postgres:16
```

Then run:
```bash
swift test --filter PostgresEventStoreTests
```

Expected: All 20 tests pass. Fix any failures.

**Step 3: Commit**

```bash
git add Tests/SongbirdPostgresTests/PostgresEventStoreTests.swift
git commit -m "Add PostgresEventStore tests mirroring SQLite test suite"
```

---

### Task 8: PostgresPositionStore and PostgresSnapshotStore Tests

**Files:**
- Create: `Tests/SongbirdPostgresTests/PostgresPositionStoreTests.swift`
- Create: `Tests/SongbirdPostgresTests/PostgresSnapshotStoreTests.swift`

**Context:** Mirror the SQLite position store tests (5 tests) and snapshot store tests (4 tests).

**Step 1: Write position store tests**

Create `Tests/SongbirdPostgresTests/PostgresPositionStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres

@Suite("PostgresPositionStore")
struct PostgresPositionStoreTests {

    @Test func loadReturnsNilForUnknownSubscriber() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            let position = try await store.load(subscriberId: "unknown")
            #expect(position == nil)
        }
    }

    @Test func saveAndLoad() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "projector-1", globalPosition: 42)
            let position = try await store.load(subscriberId: "projector-1")
            #expect(position == 42)
        }
    }

    @Test func saveOverwritesPrevious() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "projector-1", globalPosition: 10)
            try await store.save(subscriberId: "projector-1", globalPosition: 25)
            let position = try await store.load(subscriberId: "projector-1")
            #expect(position == 25)
        }
    }

    @Test func subscribersAreIsolated() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "sub-a", globalPosition: 5)
            try await store.save(subscriberId: "sub-b", globalPosition: 99)
            let posA = try await store.load(subscriberId: "sub-a")
            let posB = try await store.load(subscriberId: "sub-b")
            #expect(posA == 5)
            #expect(posB == 99)
        }
    }

    @Test func persistsPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "sub-1", globalPosition: 7)

            let position = try await store.load(subscriberId: "sub-1")
            #expect(position == 7)

            // Save again to exercise the ON CONFLICT UPDATE path
            try await store.save(subscriberId: "sub-1", globalPosition: 14)
            let updated = try await store.load(subscriberId: "sub-1")
            #expect(updated == 14)
        }
    }
}
```

**Step 2: Write snapshot store tests**

Create `Tests/SongbirdPostgresTests/PostgresSnapshotStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres

private enum PGSnapAggregate: Aggregate {
    struct State: Sendable, Equatable, Codable {
        var count: Int
    }

    enum Event: Songbird.Event {
        case incremented

        var eventType: String { "Incremented" }
    }

    enum Failure: Error { case none }

    static let category = "snap"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        State(count: state.count + 1)
    }
}

@Suite("PostgresSnapshotStore")
struct PostgresSnapshotStoreTests {

    @Test func loadReturnsNilWhenNoSnapshot() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream = StreamName(category: "snap", id: "1")
            let result: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream)
            #expect(result == nil)
        }
    }

    @Test func saveAndLoad() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream = StreamName(category: "snap", id: "1")
            let state = PGSnapAggregate.State(count: 42)
            try await store.save(state, version: 10, for: stream)
            let loaded: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream)
            #expect(loaded?.state == state)
            #expect(loaded?.version == 10)
        }
    }

    @Test func saveOverwritesPreviousSnapshot() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream = StreamName(category: "snap", id: "1")
            try await store.save(PGSnapAggregate.State(count: 1), version: 5, for: stream)
            try await store.save(PGSnapAggregate.State(count: 99), version: 50, for: stream)
            let loaded: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream)
            #expect(loaded?.state == PGSnapAggregate.State(count: 99))
            #expect(loaded?.version == 50)
        }
    }

    @Test func differentStreamsAreIndependent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream1 = StreamName(category: "snap", id: "1")
            let stream2 = StreamName(category: "snap", id: "2")
            try await store.save(PGSnapAggregate.State(count: 10), version: 5, for: stream1)
            try await store.save(PGSnapAggregate.State(count: 20), version: 8, for: stream2)
            let loaded1: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream1)
            let loaded2: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream2)
            #expect(loaded1?.state.count == 10)
            #expect(loaded1?.version == 5)
            #expect(loaded2?.state.count == 20)
            #expect(loaded2?.version == 8)
        }
    }
}
```

**Step 3: Run all Postgres tests**

```bash
swift test --filter SongbirdPostgresTests
```

Expected: All position store tests (5) and snapshot store tests (4) pass.

**Step 4: Commit**

```bash
git add Tests/SongbirdPostgresTests/PostgresPositionStoreTests.swift Tests/SongbirdPostgresTests/PostgresSnapshotStoreTests.swift
git commit -m "Add PostgresPositionStore and PostgresSnapshotStore tests"
```

---

### Task 9: Hash Chain Verification Tests

**Files:**
- Create: `Tests/SongbirdPostgresTests/PostgresChainVerificationTests.swift`

**Context:** Three chain verification tests from the SQLite suite: intact chain, empty store, and tampered event detection. The tampered event test uses `rawExecute` to corrupt data.

**Step 1: Write chain verification tests**

Create `Tests/SongbirdPostgresTests/PostgresChainVerificationTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres
@testable import SongbirdTesting

@Suite("PostgresEventStore Chain Verification")
struct PostgresChainVerificationTests {
    let stream = StreamName(category: "account", id: "abc")

    func makeRegistry() -> EventTypeRegistry {
        let registry = EventTypeRegistry()
        registry.register(PGAccountEvent.self, eventTypes: ["Credited", "Debited"])
        return registry
    }

    @Test func hashChainIsIntactAfterAppends() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.debited(amount: 50, note: "fee"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let result = try await store.verifyChain()
            #expect(result.intact == true)
            #expect(result.eventsVerified == 3)
            #expect(result.brokenAtSequence == nil)
        }
    }

    @Test func emptyStoreChainIsIntact() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let result = try await store.verifyChain()
            #expect(result.intact == true)
            #expect(result.eventsVerified == 0)
        }
    }

    @Test func tamperedEventBreaksChain() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            // Tamper with the second event's data
            try await store.rawExecute(
                "UPDATE events SET data = '{\"credited\":{\"amount\":999}}'::jsonb WHERE global_position = 2"
            )

            let result = try await store.verifyChain()
            #expect(result.intact == false)
            #expect(result.eventsVerified == 1)
            #expect(result.brokenAtSequence == 2)
        }
    }
}
```

**Step 2: Run chain verification tests**

```bash
swift test --filter PostgresChainVerificationTests
```

Expected: All 3 tests pass. Note: The `brokenAtSequence` value will be `2` (the BIGSERIAL global_position, 1-based) because the chain verification uses the raw `global_position` column value, matching how `SQLiteEventStore.verifyChain()` returns the raw `global_position`.

**Step 3: Commit**

```bash
git add Tests/SongbirdPostgresTests/PostgresChainVerificationTests.swift
git commit -m "Add hash chain verification tests for PostgresEventStore"
```

---

### Task 10: Clean Build and Full Test Suite

**Files:**
- No new files

**Context:** Verify that everything compiles cleanly and all tests pass — both the new Postgres tests AND the existing test suite.

**Step 1: Verify clean build**

```bash
swift build 2>&1
```

Expected: Clean build with zero warnings and zero errors.

**Step 2: Run the full test suite**

```bash
swift test 2>&1
```

Expected: All tests pass (existing SQLite tests + new Postgres tests). If Postgres tests fail because no Postgres instance is running, that's expected in CI without Postgres configured — verify the existing tests still pass and the Postgres tests pass with a Postgres instance running.

**Step 3: Run just the Postgres tests separately**

```bash
swift test --filter SongbirdPostgresTests 2>&1
```

Expected: All Postgres tests pass (20 event store + 5 position store + 4 snapshot store + 3 chain verification = 32 tests).

**Step 4: Fix any issues**

If any tests fail or warnings appear, fix them. Common issues:
- PostgresNIO API differences from what's shown in the plan → adjust method signatures
- Timestamp format mismatch in hash chain → verify the `to_char` format matches `ISO8601DateFormatter` output
- JSONB encoding issues → ensure JSON strings are properly cast with `::jsonb`
- `PostgresRandomAccessRow` API differences → switch to tuple-based decoding in query methods

---

### Task 11: Changelog Entry

**Files:**
- Create: `changelog/0020-songbird-postgres.md`

**Context:** Document what was implemented.

**Step 1: Write the changelog entry**

Create `changelog/0020-songbird-postgres.md`:

```markdown
# SongbirdPostgres Module

Added the `SongbirdPostgres` module providing PostgreSQL implementations of `EventStore`, `PositionStore`, and `SnapshotStore`.

## What Changed

### New Module: SongbirdPostgres

**Dependencies:** PostgresNIO (>= 1.29.0), postgres-migrations (>= 1.1.0)

**PostgresEventStore** — Full `EventStore` conformance with Postgres-native features:
- JSONB for event data and metadata (instead of TEXT)
- TIMESTAMPTZ for timestamps (instead of ISO8601 strings)
- `UNIQUE (stream_name, position)` constraint for optimistic concurrency
- `BIGSERIAL` global_position (0-based externally, matching SQLite behavior)
- SHA-256 hash chain with `verifyChain(batchSize:)` for tamper detection
- `NOTIFY songbird_events` after each append (for future LISTEN-based subscriptions)
- Struct-based (not actor) — PostgresClient manages connection pooling

**PostgresPositionStore** — `PositionStore` conformance with upsert semantics.

**PostgresSnapshotStore** — `SnapshotStore` conformance with JSONB state storage.

**SongbirdPostgresMigrations** — Schema creation via `postgres-migrations`:
- `events` table with indexes on stream and category
- `subscriber_positions` table
- `snapshots` table

### Tests

32 tests mirroring the SQLite test suite:
- 20 event store tests (append, concurrency, read stream, read category, read last, stream version)
- 5 position store tests
- 4 snapshot store tests
- 3 chain verification tests

Tests require a running Postgres instance (configurable via environment variables).

## Future Work

- **PostgresEventSubscription**: LISTEN/NOTIFY-based event subscription for near-instant delivery
- **EventStore protocol improvements**: Feedback from implementation experience
- **JSONB indexing**: GIN indexes on event data for content queries
- **Warbler Postgres variants**: Distributed and P2P demos using Postgres instead of shared SQLite
```

**Step 2: Commit**

```bash
git add changelog/0020-songbird-postgres.md
git commit -m "Add SongbirdPostgres changelog entry"
```

---

## Implementation Notes

### PostgresNIO API Adaptation

The code in this plan is based on PostgresNIO's documented API patterns. During implementation, you may need to adjust:

1. **`PostgresClient.withTransaction`** — The actual signature may accept a logger parameter or use a different closure pattern. Check the source.
2. **Row decoding** — The plan shows both tuple-based decoding (`rows.decode((Type1, Type2).self)`) and random-access decoding (`row[data: 0].decode(Type.self, context: .default)`). Prefer tuple-based decoding where the column set is known at compile time.
3. **`PostgresQuery(unsafeSQL:)`** — This is for the `rawExecute` test helper only. The actual API may differ; check `PostgresQuery` constructors.
4. **`PSQLError.serverInfo`** — Verify the exact path to access the SQL state code. It may be `error.serverInfo?[.sqlState]` or a different accessor.
5. **`postgres-migrations` API** — The `DatabaseMigration` protocol shape may differ. Check the package's actual API for `apply(connection:logger:)`, `revert(connection:logger:)`, and the `name`/`group` properties.

### Timestamp Handling in Hash Chain

The hash chain uses ISO8601 strings for the timestamp component. During append, we format with `ISO8601DateFormatter`. During verification, we use `to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')` to reproduce the same format from the stored `TIMESTAMPTZ`. If these don't match, the chain will appear broken. Test this carefully and adjust the `to_char` format if needed.

### BIGSERIAL Global Position

BIGSERIAL starts at 1, but the `EventStore` protocol uses 0-based global positions. All Postgres stores subtract 1 from the raw `global_position` column when returning `RecordedEvent`, and add 1 when querying by global position (in `readCategories`).

### EventStore Protocol Feedback

Per the user's request: while implementing, note any opportunities to improve the `EventStore` protocol. Document these as "Future Work" observations rather than making protocol changes in this phase.
