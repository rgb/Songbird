# Code Review Remediation (Round 2) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all remaining issues from the second comprehensive code review: 3 critical, 6 important, 6 suggestions, and 8 test coverage gaps.

**Architecture:** Fixes grouped by severity. Critical safety issues first, then important improvements, then suggestions and test gaps. The NIO ByteToMessageHandler Sendable warning is a known upstream issue and is documented but not fixed (requires NIO update).

**Tech Stack:** Swift 6.2, SQLite.swift, swift-metrics, swift-log, NIOCore, Smew (DuckDB)

---

## Task 1: Critical -- Force Unwrap in Transport.swift Task Group

**Severity:** Critical -- crash if task group is cancelled before producing a result

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:120`

**Step 1: Replace force unwrap with guard let**

In `Sources/SongbirdDistributed/Transport.swift`, replace line 120:

```swift
// BEFORE (line 120):
let result = try await group.next()!

// AFTER:
guard let result = try await group.next() else {
    throw SongbirdDistributedError.remoteCallFailed("Call cancelled")
}
```

**Step 2: Run tests to verify**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
fix: replace force unwrap in TransportClient task group
```

---

## Task 2: Critical -- Force Casts in SQLiteEventStore

**Severity:** Critical -- corrupted DB rows crash instead of throwing

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:48-52,253-258`

**Step 1: Fix `schemaVersion` force casts (lines 48-52)**

```swift
// BEFORE:
private static func schemaVersion(_ db: Connection) throws -> Int {
    let tableExists = try db.scalar(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
    ) as! Int64
    if tableExists == 0 { return 0 }
    return try Int(db.scalar("SELECT version FROM schema_version") as! Int64)
}

// AFTER:
private static func schemaVersion(_ db: Connection) throws -> Int {
    guard let tableExists = try db.scalar(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
    ) as? Int64 else {
        return 0
    }
    if tableExists == 0 { return 0 }
    guard let version = try db.scalar("SELECT version FROM schema_version") as? Int64 else {
        throw SQLiteEventStoreError.corruptedRow(column: "version", globalPosition: nil)
    }
    return Int(version)
}
```

**Step 2: Fix `verifyChain` force casts (lines 253-258)**

```swift
// BEFORE:
let globalPos = row[0] as! Int64
let eventType = row[1] as! String
let streamName = row[2] as! String
let data = row[3] as! String
let timestamp = row[4] as! String
let storedHash = row[5] as? String

// AFTER:
guard let globalPos = row[0] as? Int64,
      let eventType = row[1] as? String,
      let streamName = row[2] as? String,
      let data = row[3] as? String,
      let timestamp = row[4] as? String
else {
    throw SQLiteEventStoreError.corruptedRow(
        column: "chain_verification",
        globalPosition: nil
    )
}
let storedHash = row[5] as? String
```

**Step 3: Check `recordedEvent(from:)` for similar force casts**

Read and fix the `recordedEvent(from:)` helper method if it also uses force casts.

**Step 4: Run tests to verify**

Run: `swift test --filter SongbirdSQLiteTests 2>&1 | tail -5`
Expected: All tests pass

**Step 5: Commit**

```
fix: replace force casts with safe type coercion in SQLiteEventStore
```

---

## Task 3: Critical -- SQLEscaping Tests

**Severity:** Critical -- security-critical code with zero test coverage

**Files:**
- Create: `Tests/SongbirdSmewTests/SQLEscapingTests.swift`

**Step 1: Write tests**

Create `Tests/SongbirdSmewTests/SQLEscapingTests.swift`:

```swift
@testable import SongbirdSmew
import Testing

@Suite("SQL Escaping")
struct SQLEscapingTests {
    // MARK: - escapeSQLString

    @Test("escapeSQLString passes through plain strings")
    func plainString() {
        #expect(escapeSQLString("hello world") == "hello world")
    }

    @Test("escapeSQLString doubles single quotes")
    func singleQuotes() {
        #expect(escapeSQLString("O'Brien") == "O''Brien")
    }

    @Test("escapeSQLString handles multiple single quotes")
    func multipleSingleQuotes() {
        #expect(escapeSQLString("it's a 'test'") == "it''s a ''test''")
    }

    @Test("escapeSQLString handles empty string")
    func emptyString() {
        #expect(escapeSQLString("") == "")
    }

    @Test("escapeSQLString handles string of only quotes")
    func onlyQuotes() {
        #expect(escapeSQLString("'''") == "''''''")
    }

    @Test("escapeSQLString does not escape double quotes")
    func doubleQuotesUntouched() {
        #expect(escapeSQLString("say \"hello\"") == "say \"hello\"")
    }

    @Test("escapeSQLString handles path with single quote")
    func pathWithQuote() {
        #expect(escapeSQLString("/data/user's/catalog.db") == "/data/user''s/catalog.db")
    }

    // MARK: - escapeSQLIdentifier

    @Test("escapeSQLIdentifier passes through plain strings")
    func identifierPlain() {
        #expect(escapeSQLIdentifier("my_table") == "my_table")
    }

    @Test("escapeSQLIdentifier doubles double quotes")
    func identifierDoubleQuotes() {
        #expect(escapeSQLIdentifier("my\"table") == "my\"\"table")
    }

    @Test("escapeSQLIdentifier handles multiple double quotes")
    func identifierMultipleQuotes() {
        #expect(escapeSQLIdentifier("a\"b\"c") == "a\"\"b\"\"c")
    }

    @Test("escapeSQLIdentifier handles empty string")
    func identifierEmpty() {
        #expect(escapeSQLIdentifier("") == "")
    }

    @Test("escapeSQLIdentifier does not escape single quotes")
    func identifierSingleQuotesUntouched() {
        #expect(escapeSQLIdentifier("it's") == "it's")
    }
}
```

**Step 2: Run tests to verify they pass**

Run: `swift test --filter SongbirdSmewTests/SQLEscapingTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
test: add comprehensive tests for SQL escaping functions
```

---

## Task 4: Important -- EventTypeRegistry Lock Granularity

**Severity:** Important -- TOCTOU between lock/unlock/lock in decode()

**Files:**
- Modify: `Sources/Songbird/EventTypeRegistry.swift:78-105`

**Step 1: Snapshot decoder + upcast chain in a single locked section**

Replace the `decode` method (lines 78-105):

```swift
public func decode(_ recorded: RecordedEvent) throws -> any Event {
    // Snapshot the decoder and full upcast chain under a single lock acquisition
    // to prevent TOCTOU races if registration happens concurrently with decoding.
    let (decoder, upcastChain) = lock.withLock {
        let decoder = decoders[recorded.eventType]

        // Pre-build the upcast chain: walk from recorded.eventType through upcasts
        var chain: [@Sendable (any Event) -> any Event] = []
        var currentType = recorded.eventType
        while let upcastFn = upcasts[currentType] {
            chain.append(upcastFn)
            // We need the next event type to continue the chain, but we don't have
            // the decoded event yet. For chained upcasts, each upcast registration
            // knows its NewEvent type. Since we can't get eventType without decoding,
            // we stop here -- the upcast function itself produces the new type.
            // This is safe because registration always happens before decoding starts.
            break
        }

        return (decoder, chain)
    }

    guard let decoder else {
        throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
    }

    var event = try decoder(recorded.data)

    // Apply the upcast chain. After each upcast, look up the next one.
    // This second lookup is safe because registrations are append-only
    // (they never remove or replace entries).
    var nextEventType = recorded.eventType
    while true {
        let upcastFn = lock.withLock { upcasts[nextEventType] }
        guard let upcastFn else { break }
        event = upcastFn(event)
        nextEventType = event.eventType
    }

    return event
}
```

Actually, this is more complex than needed. The real issue is that between separate lock/unlock cycles, registrations could change. But in practice, registrations happen at startup before any decoding. The simpler fix is to add a `withLock` helper to NSLock and use it for cleaner code, plus document the startup-only registration contract:

```swift
public func decode(_ recorded: RecordedEvent) throws -> any Event {
    let decoder = lock.withLock { decoders[recorded.eventType] }

    guard let decoder else {
        throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
    }

    var event = try decoder(recorded.data)

    // Walk the upcast chain until no more upcasts exist.
    // Registration is expected to happen at startup before any decoding,
    // so the dictionaries are effectively immutable during decode.
    var currentEventType = recorded.eventType
    while true {
        let upcastFn = lock.withLock { upcasts[currentEventType] }
        guard let upcastFn else { break }
        event = upcastFn(event)
        currentEventType = event.eventType
    }

    return event
}
```

Add a `withLock` helper to NSLock (if not already present):

```swift
extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
```

Note: `NSLock.withLock` is available in newer Foundation versions. If the project's deployment target includes it, use it directly. Otherwise add the extension.

Also add a doc comment to the class noting the registration contract:

```swift
/// `EventTypeRegistry` is safe to read and write from any isolation domain.
///
/// **Important:** All registration (`register`, `registerUpcast`) should happen
/// at startup before any calls to `decode`. The registry does not guarantee
/// atomicity between registration and concurrent decoding.
```

**Step 2: Run tests to verify**

Run: `swift test --filter SongbirdTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
fix: use withLock in EventTypeRegistry and document registration contract
```

---

## Task 5: Important -- ProjectionFlushMiddleware Error Handling

**Severity:** Important -- swallows all errors, not just timeouts

**Files:**
- Modify: `Sources/SongbirdHummingbird/ProjectionFlushMiddleware.swift:21`

**Step 1: Only swallow timeout errors**

Replace line 21:

```swift
// BEFORE:
try? await pipeline.waitForIdle()

// AFTER:
do {
    try await pipeline.waitForIdle()
} catch is ProjectionPipelineError {
    // Timeout is expected in tests -- swallow it
} catch is CancellationError {
    // Task cancelled -- swallow it
}
// Other errors (e.g., database failures) propagate naturally
// since waitForIdle only throws timeout or cancellation.
```

Actually, let me check what `waitForIdle` can actually throw. Looking at ProjectionPipeline:
- `waitForIdle` calls `waitForProjection`
- `waitForProjection` throws `ProjectionPipelineError.timeout`, `CancellationError`, or propagates from `Task.checkCancellation()`

So in practice, `waitForIdle` only throws timeout or cancellation. The `try?` is actually fine -- but it's unclear to readers. Let's make it explicit:

```swift
// AFTER:
do {
    try await pipeline.waitForIdle()
} catch {
    // waitForIdle can throw timeout or cancellation -- both are safe
    // to ignore in the flush middleware, since the response is already
    // computed and we're just waiting for projections to catch up.
}
```

This is actually the same behavior, but now the reasoning is explicit in the comment.

**Step 2: Run tests to verify**

Run: `swift test --filter SongbirdHummingbirdTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
docs: document why ProjectionFlushMiddleware swallows all errors
```

---

## Task 6: Important -- Document NIO Sendable Warning

**Severity:** Important -- known upstream issue, cannot fix in our code

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:37,78` (add comments)

**Step 1: Add documentation explaining the warning**

Add a comment above the NIO handler classes and the pipeline setup:

At the top of the NIO Handlers section (before line 164):

```swift
// MARK: - NIO Handlers
//
// Note: These handlers are marked @unchecked Sendable because NIO channel handlers
// must be classes, and NIO's own ByteToMessageHandler has Sendable conformance
// explicitly unavailable (a known NIO issue). Our handlers are either stateless
// (MessageFrameDecoder, MessageFrameEncoder) or hold only Sendable references
// (ServerInboundHandler holds `any WireMessageHandler`, ClientInboundHandler holds
// `TransportClient` which is an actor). The @unchecked Sendable is safe because
// NIO guarantees handler methods are called on the channel's EventLoop thread.
//
// The build warning "Conformance of 'ByteToMessageHandler<Decoder>' to 'Sendable'
// is unavailable" comes from SwiftNIO upstream and cannot be fixed in our code.
// Track: https://github.com/apple/swift-nio/issues/xxxx
```

**Step 2: Commit**

```
docs: document NIO ByteToMessageHandler Sendable warning (upstream issue)
```

---

## Task 7: Important -- Make Cold Schema Name Configurable

**Severity:** Important -- hard-coded "lake" prevents customization

**Files:**
- Modify: `Sources/SongbirdSmew/DuckLakeConfig.swift`
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift:67`

**Step 1: Add schemaName to DuckLakeConfig**

In `Sources/SongbirdSmew/DuckLakeConfig.swift`, add a property:

```swift
public struct DuckLakeConfig: Sendable {
    // ... existing properties ...

    /// Schema name for the cold tier in DuckDB (default: "lake").
    public let schemaName: String

    public init(
        catalogPath: String,
        dataPath: String,
        backend: Backend = .local,
        schemaName: String = "lake"
    ) {
        self.catalogPath = catalogPath
        self.dataPath = dataPath
        self.backend = backend
        self.schemaName = schemaName
    }
}
```

**Step 2: Use config.schemaName in ReadModelStore**

In `Sources/SongbirdSmew/ReadModelStore.swift`:

Replace the static `coldSchemaName` (line 67) with an instance property:

```swift
// BEFORE:
static let coldSchemaName = "lake"

// AFTER:
let coldSchemaName: String
```

Update `init` to set it:
```swift
// In init, after setting isTiered:
if case .tiered(let config) = storageMode {
    self.coldSchemaName = config.schemaName
} else {
    self.coldSchemaName = "lake"  // default, unused in non-tiered mode
}
```

Update `attachDuckLake` to take the schema name as a parameter:
```swift
private static func attachDuckLake(connection: Connection, config: DuckLakeConfig) throws {
    // ...
    try connection.execute(
        "ATTACH 'ducklake:\(catalogPath)' AS \(escapeSQLIdentifier(config.schemaName)) (DATA_PATH '\(dataPath)')"
    )
}
```

Update all references from `Self.coldSchemaName` to `coldSchemaName` (instance property).

**Step 3: Run tests to verify**

Run: `swift test --filter SongbirdSmewTests 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```
feat: make cold tier schema name configurable via DuckLakeConfig
```

---

## Task 8: Important -- Guard rawExecute for Test-Only Use

**Severity:** Important -- arbitrary SQL execution available in production

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:297-300`
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift` (check for similar)

**Step 1: Add documentation and conditional compilation**

In `Sources/SongbirdPostgres/PostgresEventStore.swift`:

```swift
// BEFORE:
/// Execute raw SQL. Intended for test scenarios (e.g., corrupting data to test chain verification).
public func rawExecute(_ sql: String) async throws {
    try await client.query(PostgresQuery(unsafeSQL: sql))
}

// AFTER:
/// Execute raw SQL. **Test-only** — used for scenarios like corrupting data
/// to test chain verification. Not available in release builds.
#if DEBUG
public func rawExecute(_ sql: String) async throws {
    try await client.query(PostgresQuery(unsafeSQL: sql))
}
#endif
```

Check if SQLiteEventStore has the same pattern and apply `#if DEBUG` there too.

**Step 2: Update test call sites if needed**

Test files are always compiled in DEBUG mode, so no changes needed to tests.

**Step 3: Run tests to verify**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```
fix: guard rawExecute behind #if DEBUG
```

---

## Task 9: Suggestions -- InjectorRunner Metrics + Minor Improvements

**Severity:** Suggestions

**Files:**
- Modify: `Sources/Songbird/InjectorRunner.swift`
- Modify: `Sources/SongbirdHummingbird/SongbirdServices.swift` (lifecycle logging)

**Step 1: Add metrics to InjectorRunner**

In `Sources/Songbird/InjectorRunner.swift`, add metrics matching GatewayRunner's pattern:

```swift
import Logging
import Metrics

public actor InjectorRunner<I: Injector> {
    private let injector: I
    private let store: any EventStore
    private let logger = Logger(label: "songbird.injector-runner")

    // ... existing init ...

    public func run() async throws {
        for try await inbound in injector.events() {
            let start = ContinuousClock.now
            let result: Result<RecordedEvent, any Error>
            do {
                let recorded = try await store.append(
                    inbound.event,
                    to: inbound.stream,
                    metadata: inbound.metadata,
                    expectedVersion: nil
                )
                result = .success(recorded)
                let elapsed = ContinuousClock.now - start
                Metrics.Timer(
                    label: "songbird_injector_append_duration_seconds"
                ).recordNanoseconds(elapsed.nanoseconds)
                Counter(
                    label: "songbird_injector_append_total",
                    dimensions: [("status", "success")]
                ).increment()
            } catch {
                result = .failure(error)
                let elapsed = ContinuousClock.now - start
                Metrics.Timer(
                    label: "songbird_injector_append_duration_seconds"
                ).recordNanoseconds(elapsed.nanoseconds)
                Counter(
                    label: "songbird_injector_append_total",
                    dimensions: [("status", "failure")]
                ).increment()
                logger.error("Injector append failed",
                    metadata: [
                        "event_type": "\(inbound.event.eventType)",
                        "stream": "\(inbound.stream)",
                        "error": "\(error)",
                    ])
            }
            await injector.didAppend(inbound, result: result)
        }
    }
}
```

**Step 2: Add lifecycle logging to SongbirdServices**

In `Sources/SongbirdHummingbird/SongbirdServices.swift`, add a logger and log service start:

```swift
import Logging

// Inside the actor, add:
private let logger = Logger(label: "songbird.services")

// At the start of run():
logger.info("Starting SongbirdServices",
    metadata: [
        "projector_count": "\(projectors.count)",
        "runner_count": "\(runners.count)",
    ])
```

**Step 3: Run tests to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Clean build

**Step 4: Commit**

```
feat: add metrics to InjectorRunner and lifecycle logging to SongbirdServices
```

---

## Task 10: Test Coverage -- WireProtocol and Transport Tests

**Severity:** Important test gap

**Files:**
- Create: `Tests/SongbirdDistributedTests/WireProtocolTests.swift`

**Step 1: Write WireProtocol serialization tests**

```swift
import Foundation
import Testing
@testable import SongbirdDistributed

@Suite("WireProtocol Serialization")
struct WireProtocolTests {
    @Test("Call message round-trips through JSON")
    func callRoundTrip() throws {
        let call = WireMessage.call(.init(
            requestId: 42,
            actorName: "handler",
            targetName: "doWork",
            arguments: Data("test".utf8)
        ))
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .call(let decodedCall) = decoded else {
            Issue.record("Expected .call")
            return
        }
        #expect(decodedCall.requestId == 42)
        #expect(decodedCall.actorName == "handler")
        #expect(decodedCall.targetName == "doWork")
        #expect(decodedCall.arguments == Data("test".utf8))
    }

    @Test("Result message round-trips through JSON")
    func resultRoundTrip() throws {
        let result = WireMessage.result(.init(requestId: 1, value: Data("ok".utf8)))
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .result(let decodedResult) = decoded else {
            Issue.record("Expected .result")
            return
        }
        #expect(decodedResult.requestId == 1)
        #expect(decodedResult.value == Data("ok".utf8))
    }

    @Test("Error message round-trips through JSON")
    func errorRoundTrip() throws {
        let err = WireMessage.error(.init(requestId: 99, message: "not found"))
        let data = try JSONEncoder().encode(err)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .error(let decodedErr) = decoded else {
            Issue.record("Expected .error")
            return
        }
        #expect(decodedErr.requestId == 99)
        #expect(decodedErr.message == "not found")
    }

    @Test("Malformed JSON throws DecodingError")
    func malformedJSON() throws {
        let badData = Data("{\"type\":\"unknown\",\"payload\":{}}".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WireMessage.self, from: badData)
        }
    }

    @Test("Empty data throws DecodingError")
    func emptyData() throws {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WireMessage.self, from: Data())
        }
    }

    @Test("Call with empty arguments round-trips")
    func emptyArguments() throws {
        let call = WireMessage.call(.init(
            requestId: 0,
            actorName: "",
            targetName: "",
            arguments: Data()
        ))
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .call(let decodedCall) = decoded else {
            Issue.record("Expected .call")
            return
        }
        #expect(decodedCall.arguments == Data())
    }

    @Test("Large arguments round-trip")
    func largeArguments() throws {
        let largeData = Data(repeating: 0xAB, count: 100_000)
        let call = WireMessage.call(.init(
            requestId: 1,
            actorName: "handler",
            targetName: "bigCall",
            arguments: largeData
        ))
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .call(let decodedCall) = decoded else {
            Issue.record("Expected .call")
            return
        }
        #expect(decodedCall.arguments == largeData)
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdDistributedTests/WireProtocolTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
test: add WireProtocol serialization tests
```

---

## Task 11: Test Coverage -- EventTypeRegistry Error Paths + Concurrency

**Severity:** Important test gap

**Files:**
- Modify: `Tests/SongbirdTests/EventUpcastTests.swift` (or relevant registry test file)

**Step 1: Find existing registry tests**

Check which test file tests EventTypeRegistry and add the missing cases:

```swift
@Test("decode throws for unregistered event type")
func decodeUnregisteredType() throws {
    let registry = EventTypeRegistry()
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "test", id: "1"),
        position: 0,
        globalPosition: 0,
        eventType: "UnknownEvent",
        data: Data("{}".utf8),
        metadata: EventMetadata(),
        timestamp: Date()
    )
    #expect(throws: EventTypeRegistryError.self) {
        _ = try registry.decode(recorded)
    }
}

@Test("decode with corrupted data throws DecodingError")
func decodeCorruptedData() throws {
    let registry = EventTypeRegistry()
    registry.register(SomeTestEvent.self, eventTypes: ["SomeTestEvent"])
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "test", id: "1"),
        position: 0,
        globalPosition: 0,
        eventType: "SomeTestEvent",
        data: Data("not json".utf8),
        metadata: EventMetadata(),
        timestamp: Date()
    )
    #expect(throws: DecodingError.self) {
        _ = try registry.decode(recorded)
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
test: add EventTypeRegistry error path tests
```

---

## Task 12: Clean Build + Full Test Suite + Changelog

**Files:**
- Create: `changelog/0028-code-review-remediation-round2.md`

**Step 1: Verify clean build**

Run: `swift build 2>&1 | grep -E "warning:|error:|Build complete"`
Expected: "Build complete!" with no new warnings (the NIO ByteToMessageHandler warning is expected and documented)

**Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 3: Write changelog entry**

Create `changelog/0028-code-review-remediation-round2.md`:

```markdown
# Code Review Remediation (Round 2)

Fixes from the second comprehensive code review of the Songbird framework.

## Critical Fixes
- **Force unwrap removed**: `TransportClient.call` task group `group.next()!` replaced with guard let
- **Force casts removed**: `SQLiteEventStore.schemaVersion` and `verifyChain` use safe type coercion
- **SQL escaping tests**: Comprehensive test suite for `escapeSQLString` and `escapeSQLIdentifier`

## Important Fixes
- **EventTypeRegistry**: Cleaner lock usage with `withLock`, documented registration-before-decode contract
- **ProjectionFlushMiddleware**: Documented error swallowing rationale
- **NIO Sendable warning**: Documented as known upstream issue with justification for @unchecked Sendable
- **Cold schema name**: Now configurable via `DuckLakeConfig.schemaName` (default: "lake")
- **rawExecute**: Guarded behind `#if DEBUG` in both Postgres and SQLite stores

## Suggestions
- **InjectorRunner**: Added metrics (append duration + success/failure counters) matching GatewayRunner
- **SongbirdServices**: Added lifecycle logging on service start

## Test Coverage
- WireProtocol serialization round-trip tests (including malformed input, large payloads)
- EventTypeRegistry error path tests (unregistered types, corrupted data)
```

**Step 4: Commit**

```
docs: add code review remediation round 2 changelog
```
