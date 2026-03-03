# Phase 2: EventStore Implementations — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement EventTypeRegistry, InMemoryEventStore, and SQLiteEventStore with hash chaining and optimistic concurrency.

**Architecture:** EventTypeRegistry in core Songbird module. InMemoryEventStore in SongbirdTesting module (actor, array-backed). SQLiteEventStore in SongbirdSQLite module (actor, SQLite.swift, WAL mode, SHA-256 hash chaining). Both stores conform to the EventStore protocol defined in Phase 1.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing, SQLite.swift 0.15.3, CryptoKit (Apple) / swift-crypto (Linux)

**Test command:** `swift test 2>&1`

**Build command:** `swift build 2>&1`

**Design doc:** `docs/plans/2026-03-03-phase2-event-store-design.md`

---

### Task 1: Package.swift + EventTypeRegistry

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Songbird/EventTypeRegistry.swift`
- Create: `Tests/SongbirdTests/EventTypeRegistryTests.swift`

**Step 1: Update Package.swift**

Replace the entire `Package.swift` with:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Songbird",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Songbird", targets: ["Songbird"]),
        .library(name: "SongbirdTesting", targets: ["SongbirdTesting"]),
        .library(name: "SongbirdSQLite", targets: ["SongbirdSQLite"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
    ],
    targets: [
        // MARK: - Core

        .target(
            name: "Songbird"
        ),

        // MARK: - Testing

        .target(
            name: "SongbirdTesting",
            dependencies: ["Songbird"]
        ),

        // MARK: - SQLite

        .target(
            name: "SongbirdSQLite",
            dependencies: [
                "Songbird",
                .product(name: "SQLite", package: "SQLite.swift"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "SongbirdTests",
            dependencies: ["Songbird"]
        ),

        .testTarget(
            name: "SongbirdTestingTests",
            dependencies: ["SongbirdTesting"]
        ),

        .testTarget(
            name: "SongbirdSQLiteTests",
            dependencies: ["SongbirdSQLite", "SongbirdTesting"]
        ),
    ]
)
```

**Step 2: Create directory structure**

Run:
```bash
mkdir -p Sources/SongbirdTesting Sources/SongbirdSQLite Tests/SongbirdTestingTests Tests/SongbirdSQLiteTests
```

Create placeholder files so SPM can resolve:
- `Sources/SongbirdTesting/InMemoryEventStore.swift` (empty placeholder: `import Songbird`)
- `Sources/SongbirdSQLite/SQLiteEventStore.swift` (empty placeholder: `import Songbird`)
- `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift` (empty placeholder: `import Testing`)
- `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift` (empty placeholder: `import Testing`)

**Step 3: Write EventTypeRegistry tests**

Create `Tests/SongbirdTests/EventTypeRegistryTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird

struct TestDeposited: Event {
    static let eventType = "TestDeposited"
    let amount: Int
}

struct TestWithdrawn: Event {
    static let eventType = "TestWithdrawn"
    let amount: Int
    let reason: String
}

@Suite("EventTypeRegistry")
struct EventTypeRegistryTests {
    @Test func registerAndDecode() throws {
        let registry = EventTypeRegistry()
        registry.register(TestDeposited.self)

        let event = TestDeposited(amount: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: TestDeposited.eventType,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let typed = decoded as! TestDeposited
        #expect(typed.amount == 100)
    }

    @Test func decodeUnregisteredTypeThrows() throws {
        let registry = EventTypeRegistry()
        // Do NOT register TestDeposited

        let data = try JSONEncoder().encode(TestDeposited(amount: 50))
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: TestDeposited.eventType,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: (any Error).self) {
            _ = try registry.decode(recorded)
        }
    }

    @Test func registerMultipleTypes() throws {
        let registry = EventTypeRegistry()
        registry.register(TestDeposited.self)
        registry.register(TestWithdrawn.self)

        let depositData = try JSONEncoder().encode(TestDeposited(amount: 100))
        let withdrawData = try JSONEncoder().encode(TestWithdrawn(amount: 50, reason: "ATM"))

        let depositRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: TestDeposited.eventType,
            data: depositData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let withdrawRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 1,
            globalPosition: 1,
            eventType: TestWithdrawn.eventType,
            data: withdrawData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let d = try registry.decode(depositRecorded) as! TestDeposited
        let w = try registry.decode(withdrawRecorded) as! TestWithdrawn
        #expect(d.amount == 100)
        #expect(w.amount == 50)
        #expect(w.reason == "ATM")
    }
}
```

**Step 4: Implement EventTypeRegistry**

Create `Sources/Songbird/EventTypeRegistry.swift`:

```swift
import Foundation

public enum EventTypeRegistryError: Error {
    case unregisteredEventType(String)
}

public final class EventTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [String: @Sendable (Data) throws -> any Event] = [:]

    public init() {}

    public func register<E: Event>(_ type: E.Type) {
        lock.lock()
        defer { lock.unlock() }
        decoders[E.eventType] = { data in
            try JSONDecoder().decode(E.self, from: data)
        }
    }

    public func decode(_ recorded: RecordedEvent) throws -> any Event {
        lock.lock()
        let decoder = decoders[recorded.eventType]
        lock.unlock()

        guard let decoder else {
            throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
        }
        return try decoder(recorded.data)
    }
}
```

**Step 5: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings. (SongbirdTestingTests and SongbirdSQLiteTests have no tests yet, which is fine.)

**Step 6: Commit**

```bash
git add Package.swift Sources/Songbird/EventTypeRegistry.swift Tests/SongbirdTests/EventTypeRegistryTests.swift Sources/SongbirdTesting/ Sources/SongbirdSQLite/ Tests/SongbirdTestingTests/ Tests/SongbirdSQLiteTests/
git commit -m "Add EventTypeRegistry and multi-module Package.swift

EventTypeRegistry: thread-safe mapping of eventType strings to decoders.
New modules: SongbirdTesting, SongbirdSQLite (with placeholders).
New dependency: SQLite.swift 0.15.3."
```

---

### Task 2: InMemoryEventStore

**Files:**
- Modify: `Sources/SongbirdTesting/InMemoryEventStore.swift`
- Modify: `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift`

**Step 1: Write the tests**

Replace `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift` with:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

struct Deposited: Event {
    static let eventType = "Deposited"
    let amount: Int
}

struct Withdrawn: Event {
    static let eventType = "Withdrawn"
    let amount: Int
    let reason: String
}

@Suite("InMemoryEventStore")
struct InMemoryEventStoreTests {
    func makeStore() -> InMemoryEventStore {
        let registry = EventTypeRegistry()
        registry.register(Deposited.self)
        registry.register(Withdrawn.self)
        return InMemoryEventStore(registry: registry)
    }

    let stream = StreamName(category: "account", id: "123")

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        let store = makeStore()
        let recorded = try await store.append(
            Deposited(amount: 100),
            to: stream,
            metadata: EventMetadata(traceId: "t1"),
            expectedVersion: nil
        )
        #expect(recorded.streamName == stream)
        #expect(recorded.position == 0)
        #expect(recorded.globalPosition == 0)
        #expect(recorded.eventType == "Deposited")
        #expect(recorded.metadata.traceId == "t1")
    }

    @Test func appendIncrementsPositions() async throws {
        let store = makeStore()
        let r1 = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.position == 1)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendToMultipleStreams() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let r1 = try await store.append(Deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r2.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendedDataIsDecodable() async throws {
        let store = makeStore()
        let recorded = try await store.append(Deposited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let envelope = try recorded.decode(Deposited.self)
        #expect(envelope.event.amount == 42)
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        #expect(r2.position == 1)
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        let store = makeStore()
        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        }
    }

    // MARK: - Read Stream

    @Test func readStreamReturnsEventsInOrder() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Withdrawn(amount: 50, reason: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].position == 0)
        #expect(events[1].position == 1)
        #expect(events[2].position == 2)
        #expect(events[0].eventType == "Deposited")
        #expect(events[2].eventType == "Withdrawn")
    }

    @Test func readStreamFromPosition() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 1, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].position == 1)
    }

    @Test func readStreamWithMaxCount() async throws {
        let store = makeStore()
        for i in 0..<10 {
            _ = try await store.append(Deposited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }
        let events = try await store.readStream(stream, from: 0, maxCount: 3)
        #expect(events.count == 3)
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        let store = makeStore()
        let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(Deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].streamName == s1)
        #expect(events[1].streamName == s2)
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        _ = try await store.append(Deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    // MARK: - Read Last Event

    @Test func readLastEvent() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let last = try await store.readLastEvent(in: stream)
        #expect(last != nil)
        #expect(last!.position == 1)
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        let store = makeStore()
        let last = try await store.readLastEvent(in: stream)
        #expect(last == nil)
    }

    // MARK: - Stream Version

    @Test func streamVersionReturnsLatestPosition() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let version = try await store.streamVersion(stream)
        #expect(version == 1)
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        let store = makeStore()
        let version = try await store.streamVersion(stream)
        #expect(version == -1)
    }
}
```

**Step 2: Implement InMemoryEventStore**

Replace `Sources/SongbirdTesting/InMemoryEventStore.swift` with:

```swift
import Foundation
import Songbird

public actor InMemoryEventStore: EventStore {
    private var events: [RecordedEvent] = []
    private var streamPositions: [StreamName: Int64] = [:]
    private var nextGlobalPosition: Int64 = 0
    private let registry: EventTypeRegistry

    public init(registry: EventTypeRegistry = EventTypeRegistry()) {
        self.registry = registry
    }

    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        let currentVersion = streamPositions[stream].map { $0 } ?? Int64(-1)

        if let expected = expectedVersion, expected != currentVersion {
            throw VersionConflictError(
                streamName: stream,
                expectedVersion: expected,
                actualVersion: currentVersion
            )
        }

        let position = currentVersion + 1
        let globalPosition = nextGlobalPosition
        let data = try JSONEncoder().encode(event)

        let recorded = RecordedEvent(
            id: UUID(),
            streamName: stream,
            position: position,
            globalPosition: globalPosition,
            eventType: type(of: event).eventType,
            data: data,
            metadata: metadata,
            timestamp: Date()
        )

        events.append(recorded)
        streamPositions[stream] = position
        nextGlobalPosition += 1

        return recorded
    }

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        events
            .filter { $0.streamName == stream && $0.position >= position }
            .prefix(maxCount)
            .map { $0 }
    }

    public func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        events
            .filter { $0.streamName.category == category && $0.globalPosition >= globalPosition }
            .prefix(maxCount)
            .map { $0 }
    }

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        events.last { $0.streamName == stream }
    }

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        streamPositions[stream] ?? -1
    }
}
```

**Step 3: Run tests**

Run: `swift test 2>&1`
Expected: All InMemoryEventStore tests pass, zero warnings.

**Step 4: Commit**

```bash
git add Sources/SongbirdTesting/InMemoryEventStore.swift Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift
git commit -m "Add InMemoryEventStore

Actor-based in-memory EventStore for testing.
Full protocol conformance with optimistic concurrency.
21 tests covering append, read, versioning, and category queries."
```

---

### Task 3: SQLiteEventStore — schema, migrations, and append

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Create: `Sources/SongbirdSQLite/ChainVerificationResult.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Step 1: Write the tests (append + concurrency + basic reads)**

Replace `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift` with:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdSQLite
@testable import SongbirdTesting

struct Credited: Event {
    static let eventType = "Credited"
    let amount: Int
}

struct Debited: Event {
    static let eventType = "Debited"
    let amount: Int
    let note: String
}

@Suite("SQLiteEventStore")
struct SQLiteEventStoreTests {
    func makeStore() throws -> SQLiteEventStore {
        let registry = EventTypeRegistry()
        registry.register(Credited.self)
        registry.register(Debited.self)
        return try SQLiteEventStore(path: ":memory:", registry: registry)
    }

    let stream = StreamName(category: "account", id: "abc")

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        let store = try makeStore()
        let recorded = try await store.append(
            Credited(amount: 100),
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

    @Test func appendIncrementsPositions() async throws {
        let store = try makeStore()
        let r1 = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.position == 1)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendToMultipleStreams() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let r1 = try await store.append(Credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r2.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendedDataIsDecodable() async throws {
        let store = try makeStore()
        let recorded = try await store.append(Credited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let envelope = try recorded.decode(Credited.self)
        #expect(envelope.event.amount == 42)
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        let store = try makeStore()
        _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        #expect(r2.position == 1)
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        let store = try makeStore()
        _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        let store = try makeStore()
        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        }
    }

    // MARK: - Read Stream

    @Test func readStreamReturnsEventsInOrder() async throws {
        let store = try makeStore()
        _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Debited(amount: 50, note: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].position == 0)
        #expect(events[1].position == 1)
        #expect(events[2].position == 2)
        #expect(events[0].eventType == "Credited")
        #expect(events[2].eventType == "Debited")
    }

    @Test func readStreamFromPosition() async throws {
        let store = try makeStore()
        _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 1, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].position == 1)
    }

    @Test func readStreamWithMaxCount() async throws {
        let store = try makeStore()
        for i in 0..<10 {
            _ = try await store.append(Credited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }
        let events = try await store.readStream(stream, from: 0, maxCount: 3)
        #expect(events.count == 3)
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        let store = try makeStore()
        let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(Credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        _ = try await store.append(Credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    // MARK: - Read Last / Version

    @Test func readLastEvent() async throws {
        let store = try makeStore()
        _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let last = try await store.readLastEvent(in: stream)
        #expect(last != nil)
        #expect(last!.position == 1)
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        let store = try makeStore()
        let last = try await store.readLastEvent(in: stream)
        #expect(last == nil)
    }

    @Test func streamVersionReturnsLatestPosition() async throws {
        let store = try makeStore()
        _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let version = try await store.streamVersion(stream)
        #expect(version == 1)
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        let store = try makeStore()
        let version = try await store.streamVersion(stream)
        #expect(version == -1)
    }

    // MARK: - Hash Chain

    @Test func hashChainIsIntactAfterAppends() async throws {
        let store = try makeStore()
        _ = try await store.append(Credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Debited(amount: 50, note: "fee"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let result = try await store.verifyChain()
        #expect(result.intact == true)
        #expect(result.eventsVerified == 3)
        #expect(result.brokenAtSequence == nil)
    }

    @Test func emptyStoreChainIsIntact() async throws {
        let store = try makeStore()
        let result = try await store.verifyChain()
        #expect(result.intact == true)
        #expect(result.eventsVerified == 0)
    }
}
```

**Step 2: Create ChainVerificationResult**

Create `Sources/SongbirdSQLite/ChainVerificationResult.swift`:

```swift
public struct ChainVerificationResult: Sendable, Equatable {
    public let intact: Bool
    public let eventsVerified: Int
    public let brokenAtSequence: Int64?

    public init(intact: Bool, eventsVerified: Int, brokenAtSequence: Int64? = nil) {
        self.intact = intact
        self.eventsVerified = eventsVerified
        self.brokenAtSequence = brokenAtSequence
    }
}
```

**Step 3: Implement SQLiteEventStore**

Replace `Sources/SongbirdSQLite/SQLiteEventStore.swift` with the full implementation. This is the largest file -- it includes schema setup, migrations, append with hash chaining, all read methods, and chain verification.

```swift
import CryptoKit
import Foundation
import Songbird
import SQLite

public actor SQLiteEventStore: EventStore {
    let db: Connection
    private let registry: EventTypeRegistry

    public init(path: String, registry: EventTypeRegistry) throws {
        if path == ":memory:" {
            self.db = try Connection(.inMemory)
        } else {
            self.db = try Connection(path)
        }
        self.registry = registry
        try Self.configurePragmas(db)
        try Self.migrate(db)
    }

    // MARK: - Pragmas

    private static func configurePragmas(_ db: Connection) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
    }

    // MARK: - Migrations

    private static func schemaVersion(_ db: Connection) throws -> Int {
        let tableExists = try db.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
        ) as! Int64
        if tableExists == 0 { return 0 }
        return try Int(db.scalar("SELECT version FROM schema_version") as! Int64)
    }

    private static func migrate(_ db: Connection) throws {
        let version = try schemaVersion(db)
        if version < 1 { try migrateToV1(db) }
    }

    private static func migrateToV1(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE schema_version (version INTEGER NOT NULL);
            INSERT INTO schema_version VALUES (1);

            CREATE TABLE events (
                global_position  INTEGER PRIMARY KEY AUTOINCREMENT,
                stream_name      TEXT NOT NULL,
                stream_category  TEXT NOT NULL,
                position         INTEGER NOT NULL,
                event_type       TEXT NOT NULL,
                data             TEXT NOT NULL,
                metadata         TEXT NOT NULL,
                event_id         TEXT NOT NULL,
                timestamp        TEXT NOT NULL,
                event_hash       TEXT
            );

            CREATE INDEX idx_events_stream ON events(stream_name, position);
            CREATE INDEX idx_events_category ON events(stream_category, global_position);
            CREATE UNIQUE INDEX idx_events_event_id ON events(event_id);
        """)
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

        // Optimistic concurrency check
        let currentVersion = try currentStreamVersion(streamStr)
        if let expected = expectedVersion, expected != currentVersion {
            throw VersionConflictError(
                streamName: stream,
                expectedVersion: expected,
                actualVersion: currentVersion
            )
        }

        let position = currentVersion + 1
        let eventId = UUID()
        let now = Date()
        let iso8601 = ISO8601DateFormatter().string(from: now)
        let eventData = try JSONEncoder().encode(event)
        let eventDataString = String(data: eventData, encoding: .utf8)!
        let metadataData = try JSONEncoder().encode(metadata)
        let metadataString = String(data: metadataData, encoding: .utf8)!
        let eventType = type(of: event).eventType

        // Hash chain
        let previousHash = try lastEventHash() ?? "genesis"
        let hashInput = "\(previousHash)\0\(eventType)\0\(streamStr)\0\(eventDataString)\0\(iso8601)"
        let eventHash = SHA256.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        try db.run("""
            INSERT INTO events (stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp, event_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, streamStr, category, position, eventType, eventDataString, metadataString, eventId.uuidString, iso8601, eventHash)

        let globalPosition = db.lastInsertRowid - 1  // 0-based (AUTOINCREMENT starts at 1)

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
        let rows = try db.prepare("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_name = ? AND position >= ?
            ORDER BY position ASC
            LIMIT ?
        """, stream.description, position, maxCount)

        return try rows.map { row in try recordedEvent(from: row) }
    }

    // MARK: - Read Category

    public func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let rows = try db.prepare("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_category = ? AND (global_position - 1) >= ?
            ORDER BY global_position ASC
            LIMIT ?
        """, category, globalPosition, maxCount)

        return try rows.map { row in try recordedEvent(from: row) }
    }

    // MARK: - Read Last Event

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        let rows = try db.prepare("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_name = ?
            ORDER BY position DESC
            LIMIT 1
        """, stream.description)

        for row in rows {
            return try recordedEvent(from: row)
        }
        return nil
    }

    // MARK: - Stream Version

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        try currentStreamVersion(stream.description)
    }

    // MARK: - Chain Verification

    public func verifyChain(batchSize: Int = 1000) throws -> ChainVerificationResult {
        var previousHash = "genesis"
        var verified = 0
        var offset = 0

        while true {
            let rows = try db.prepare("""
                SELECT global_position, event_type, stream_name, data, timestamp, event_hash
                FROM events
                ORDER BY global_position ASC
                LIMIT ? OFFSET ?
            """, batchSize, offset)

            var batchCount = 0
            for row in rows {
                batchCount += 1
                let globalPos = row[0] as! Int64
                let eventType = row[1] as! String
                let streamName = row[2] as! String
                let data = row[3] as! String
                let timestamp = row[4] as! String
                let storedHash = row[5] as? String

                let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(data)\0\(timestamp)"
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
        }

        return ChainVerificationResult(intact: true, eventsVerified: verified)
    }

    // MARK: - Private Helpers

    private func currentStreamVersion(_ streamName: String) throws -> Int64 {
        let result = try db.scalar("""
            SELECT MAX(position) FROM events WHERE stream_name = ?
        """, streamName)
        if let maxPos = result as? Int64 {
            return maxPos
        }
        return -1
    }

    private func lastEventHash() throws -> String? {
        let result = try db.scalar("""
            SELECT event_hash FROM events ORDER BY global_position DESC LIMIT 1
        """)
        return result as? String
    }

    private func recordedEvent(from row: Statement.Element) throws -> RecordedEvent {
        let autoincPos = row[0] as! Int64
        let globalPosition = autoincPos - 1  // 0-based
        let streamStr = row[1] as! String
        let category = row[2] as! String
        let position = row[3] as! Int64
        let eventType = row[4] as! String
        let dataStr = row[5] as! String
        let metadataStr = row[6] as! String
        let eventIdStr = row[7] as! String
        let timestampStr = row[8] as! String

        let stream = StreamName(category: category, id: extractId(from: streamStr, category: category))
        let eventData = Data(dataStr.utf8)
        let metadata = try JSONDecoder().decode(EventMetadata.self, from: Data(metadataStr.utf8))
        let eventId = UUID(uuidString: eventIdStr)!
        let timestamp = ISO8601DateFormatter().date(from: timestampStr) ?? Date()

        return RecordedEvent(
            id: eventId,
            streamName: stream,
            position: position,
            globalPosition: globalPosition,
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

**Step 4: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 5: Commit**

```bash
git add Sources/SongbirdSQLite/SQLiteEventStore.swift Sources/SongbirdSQLite/ChainVerificationResult.swift Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift
git commit -m "Add SQLiteEventStore with hash chaining

SQLite-backed EventStore with WAL mode, SHA-256 hash chain,
optimistic concurrency, and version-tracked migrations.
22 tests covering all protocol methods plus chain verification."
```

---

### Task 4: Final review — clean build, all tests pass, no warnings

**Step 1: Verify clean build**

Run: `swift build 2>&1`
Expected: Build complete, zero warnings, zero errors.

**Step 2: Verify all tests pass**

Run: `swift test 2>&1`
Expected: All tests pass across SongbirdTests, SongbirdTestingTests, and SongbirdSQLiteTests.

**Step 3: Verify file layout matches design**

Run: `find Sources -name '*.swift' | sort`
Expected:
```
Sources/Songbird/Aggregate.swift
Sources/Songbird/Command.swift
Sources/Songbird/Event.swift
Sources/Songbird/EventStore.swift
Sources/Songbird/EventTypeRegistry.swift
Sources/Songbird/Gateway.swift
Sources/Songbird/ProcessManager.swift
Sources/Songbird/Projector.swift
Sources/Songbird/StreamName.swift
Sources/SongbirdSQLite/ChainVerificationResult.swift
Sources/SongbirdSQLite/SQLiteEventStore.swift
Sources/SongbirdTesting/InMemoryEventStore.swift
```

**Step 4: Write changelog entry**

Create `changelog/0003-event-store-implementations.md`:

```markdown
# 0003 — EventStore Implementations

Implemented Phase 2 of Songbird:

- **EventTypeRegistry** — Thread-safe registry mapping eventType strings to decoders (core module)
- **InMemoryEventStore** — Actor-based in-memory EventStore for testing (SongbirdTesting module)
- **SQLiteEventStore** — SQLite-backed EventStore with WAL mode, SHA-256 hash chaining, optimistic concurrency, and version-tracked migrations (SongbirdSQLite module)
- **ChainVerificationResult** — Result type for hash chain integrity verification

New modules added: SongbirdTesting, SongbirdSQLite.
New dependency: SQLite.swift 0.15.3.
```

**Step 5: Commit changelog and push**

```bash
git add changelog/0003-event-store-implementations.md
git commit -m "Add Phase 2 changelog entry"
git push
```
