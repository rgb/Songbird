# Code Review Remediation Round 6 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all issues found in the comprehensive 5-agent code review covering every module in the Songbird framework.

**Architecture:** Fixes are grouped by theme — concurrency correctness first, then consistency fixes for patterns already fixed in one store but missed in another, then hardcoded values, logging improvements, and finally test coverage gaps. Each task is independent and can be committed separately.

**Tech Stack:** Swift 6.2, Mutex (Synchronization), PostgresNIO, SQLite.swift, SwiftNIO, Hummingbird 2, swift-metrics, swift-log

---

## Review Summary

5 parallel review agents examined every source and test file across all 7 modules. Findings:

| Severity | Count | Modules |
|----------|-------|---------|
| Critical | 3 | Core, Postgres |
| Important | 18 | All modules |
| Suggestion | 15 | All modules |

---

## Critical Issues

### Task 1: Mark `AnyReaction` closure parameters as `@Sendable`

The `AnyReaction` struct is `@unchecked Sendable` because its closures capture metatypes that Swift 6.2 doesn't consider Sendable. The `init` is `public`, meaning any consumer could construct an `AnyReaction` with closures capturing mutable state.

**Files:**
- Modify: `Sources/Songbird/EventReaction.swift:111-115`

**Changes:**

Mark the two closure parameters as `@Sendable`:

```swift
public init(
    eventTypes: [String],
    categories: [String],
    tryRoute: @escaping @Sendable (RecordedEvent) throws -> String?,
    handle: @escaping @Sendable (State, RecordedEvent) throws -> (state: State, output: [any Event])
)
```

**Verify:** `swift build` — the internal `reaction(for:categories:)` helper closures should already satisfy `@Sendable` since they only call static methods on stateless enum types.

---

### Task 2: Replace `ISO8601DateFormatter` with thread-safe parsing in PostgresEventStore

`PostgresEventStore` is a **struct** (not an actor). The `nonisolated(unsafe)` on `ISO8601DateFormatter` is unsafe because structs can be copied and the formatter (an NSObject subclass) is not Sendable. Multiple concurrent tasks calling `append()` could race on the shared formatter instance.

Additionally, line 130 has a silent `?? now` fallback that masks timestamp parse failures — this was fixed in the SQLite store (round 3) but missed here.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift`

**Changes:**

1. Remove the `iso8601Formatter` stored property (line 17).

2. Add a new error case to `PostgresEventStoreError`:
```swift
public enum PostgresEventStoreError: Error {
    case encodingFailed
    case corruptedTimestamp(String)
}
```

3. In the `append` method, replace the timestamp parsing (around line 130):
```swift
// OLD:
let returnedTimestamp = iso8601Formatter.date(from: normalizedTimestamp) ?? now

// NEW:
guard let returnedTimestamp = try? Date(normalizedTimestamp, strategy: .iso8601) else {
    throw PostgresEventStoreError.corruptedTimestamp(normalizedTimestamp)
}
```

**Verify:** `swift build` — ensure no remaining references to `iso8601Formatter`.

---

### Task 3: Add `expires_at` filtering to PostgresKeyStore queries

`PostgresKeyStore.existingKey` and `hasKey` do not filter expired keys. The SQLite store was fixed in round 5 but the Postgres store was missed. This breaks retention-based crypto shredding — expired keys are returned as if they're still valid.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresKeyStore.swift:56-85`
- Test: `Tests/SongbirdPostgresTests/PostgresKeyStoreTests.swift`

**Changes:**

1. Update `existingKey` query:
```swift
public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
    let layerStr = layer.rawValue
    let rows = try await client.query(
        "SELECT key_data FROM encryption_keys WHERE reference = \(reference) AND layer = \(layerStr) AND (expires_at IS NULL OR expires_at > NOW())"
    )
    // ... rest unchanged
}
```

2. Update `hasKey` query:
```swift
public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
    let layerStr = layer.rawValue
    let rows = try await client.query(
        "SELECT COUNT(*) FROM encryption_keys WHERE reference = \(reference) AND layer = \(layerStr) AND (expires_at IS NULL OR expires_at > NOW())"
    )
    // ... rest unchanged
}
```

3. Add a test that verifies expired keys are filtered:
```swift
@Test func expiredKeyIsNotReturned() async throws {
    try await PostgresTestHelper.withTestClient { client in
        try await PostgresTestHelper.cleanTables(client: client)
        let store = PostgresKeyStore(client: client)

        // Create a key with 1-second expiry
        let key1 = try await store.key(for: "ref", layer: .field, expiresAfter: .seconds(1))

        // Key should exist immediately
        #expect(try await store.hasKey(for: "ref", layer: .field) == true)

        // Wait for expiry
        try await Task.sleep(for: .milliseconds(1500))

        // Key should now be filtered out
        #expect(try await store.existingKey(for: "ref", layer: .field) == nil)
        #expect(try await store.hasKey(for: "ref", layer: .field) == false)

        // Requesting a key should generate a new one (different from expired)
        let key2 = try await store.key(for: "ref", layer: .field)
        #expect(key1 != key2)
    }
}
```

**Verify:** `swift test --filter PostgresKeyStoreTests`

---

## Important Issues — Concurrency

### Task 4: Replace NSLock with Mutex in EventTypeRegistry

`EventTypeRegistry` is the last remaining use of `NSLock` in the codebase. Replace with `Mutex` for consistency and to eliminate `@unchecked Sendable`.

Also fix the repeated lock acquisition in `decode()` — acquire once and copy both dictionaries.

**Files:**
- Modify: `Sources/Songbird/EventTypeRegistry.swift`

**Changes:**

1. Replace `import Foundation` with only what's needed, add `import Synchronization`.

2. Replace lock + `@unchecked Sendable`:
```swift
public final class EventTypeRegistry: Sendable {
    private struct State: Sendable {
        var decoders: [String: @Sendable (Data) throws -> any Event] = [:]
        var upcasts: [String: @Sendable (any Event) -> any Event] = [:]
    }

    private let state = Mutex(State())
```

3. Update `register`:
```swift
public func register<E: Event>(_ type: E.Type, eventTypes: [String]) {
    state.withLock { state in
        for eventType in eventTypes {
            state.decoders[eventType] = { data in
                try JSONDecoder().decode(E.self, from: data)
            }
        }
    }
}
```

4. Update `registerUpcast` — same pattern, replace `lock.withLock` with `state.withLock { state in`.

5. Update `decode` — single lock acquisition, copy both dictionaries:
```swift
public func decode(_ recorded: RecordedEvent) throws -> any Event {
    let (decoder, allUpcasts) = state.withLock { (state: inout State) in
        (state.decoders[recorded.eventType], state.upcasts)
    }

    guard let decoder else {
        throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
    }

    var event = try decoder(recorded.data)

    var currentEventType = recorded.eventType
    var visited: Set<String> = [currentEventType]
    while true {
        guard let upcastFn = allUpcasts[currentEventType] else { break }
        event = upcastFn(event)
        currentEventType = event.eventType
        guard visited.insert(currentEventType).inserted else {
            preconditionFailure("Upcast cycle detected at event type '\(currentEventType)'")
        }
    }

    return event
}
```

**Verify:** `swift test --filter SongbirdTests` — all tests pass, no `NSLock` or `@unchecked Sendable` remaining.

---

### Task 5: Add `Task.checkCancellation()` to both `verifyChain` methods

Both SQLite and Postgres `verifyChain` methods have long-running `while true` loops without cancellation checks. This was fixed for fold loops in round 5 but missed here.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:253`
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:258`

**Changes:** Add `try Task.checkCancellation()` at the top of the `while true` loop in both files:

```swift
while true {
    try Task.checkCancellation()
    // ... existing batch query ...
```

**Verify:** `swift build`

---

### Task 6: Cancel timeout tasks when NotificationSignal notifications arrive

In `NotificationSignal.wait()`, each call spawns a timeout `Task` that is never cancelled when a notification arrives. Over time this leaks sleeping tasks.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift:11-61`

**Changes:**

1. Add a timeout tasks dictionary to the actor:
```swift
private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
```

2. Update `wait` to store the timeout task:
```swift
func wait(timeout: Duration) async -> Bool {
    let id = UUID()
    return await withCheckedContinuation { continuation in
        waiters[id] = continuation
        timeoutTasks[id] = Task {
            try? await Task.sleep(for: timeout)
            self.timeoutWaiter(id: id)
        }
    }
}
```

3. Update `notifyWaiters` to cancel timeout tasks:
```swift
private func notifyWaiters() {
    let pending = waiters
    waiters.removeAll()
    for (id, continuation) in pending {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(returning: true)
    }
}
```

4. Update `timeoutWaiter` to clean up its entry:
```swift
private func timeoutWaiter(id: UUID) {
    timeoutTasks.removeValue(forKey: id)
    if let continuation = waiters.removeValue(forKey: id) {
        continuation.resume(returning: false)
    }
}
```

5. Update `stop` to cancel timeout tasks:
```swift
func stop() async {
    listenTask?.cancel()
    let pending = waiters
    waiters.removeAll()
    for (id, continuation) in pending {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(returning: false)
    }
    timeoutTasks.removeAll()
    // ... rest unchanged
}
```

**Verify:** `swift build`

---

## Important Issues — Consistency Fixes

### Task 7: Fix SQLiteKeyStore Duration truncation + silent fallback + corrupted data

Three issues in SQLiteKeyStore that were already fixed in other stores:

1. `Duration.components.seconds` truncates sub-second precision (fixed in PostgresKeyStore round 5)
2. `return newKey` fallback instead of `preconditionFailure` (fixed in PostgresKeyStore round 5)
3. Corrupted blob silently returns nil (fixed in SQLiteSnapshotStore round 5)

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteKeyStore.swift`

**Changes:**

1. Fix Duration precision (line 68):
```swift
// OLD:
iso8601Formatter.string(from: now + TimeInterval(duration.components.seconds))

// NEW:
let (seconds, attoseconds) = duration.components
let totalSeconds = Double(seconds) + Double(attoseconds) / 1e18
iso8601Formatter.string(from: now + totalSeconds)
```

2. Replace silent fallback with preconditionFailure (line 88-89):
```swift
// OLD:
// Should never happen: we just inserted or another caller did
return newKey

// NEW:
preconditionFailure("Key not found after INSERT OR IGNORE for reference '\(reference)', layer '\(layer.rawValue)'")
```

3. Add error enum and throw on corrupted data. Add before the actor declaration:
```swift
public enum SQLiteKeyStoreError: Error {
    case corruptedRow(column: String, reference: String)
}
```

4. Update `existingKey` (line 100):
```swift
guard let blob = row[0] as? Blob else {
    throw SQLiteKeyStoreError.corruptedRow(column: "key_data", reference: reference)
}
```

5. Update `hasKey` (line 121):
```swift
guard let count = row[0] as? Int64 else {
    throw SQLiteKeyStoreError.corruptedRow(column: "count", reference: reference)
}
```

**Verify:** `swift test --filter SQLiteKeyStoreTests`

---

### Task 8: Add `rawExecute` helper to SQLiteKeyStore and fix test actor isolation bypass

Two key store tests directly access `store.db` from outside the actor, bypassing its serial executor. The SQLiteEventStore solved this with a `#if DEBUG` helper.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`

**Changes:**

1. Add to SQLiteKeyStore:
```swift
#if DEBUG
/// Execute raw SQL. **Test-only** — used for scenarios like inserting
/// expired keys or corrupting data. Not available in release builds.
public func rawExecute(_ sql: String, _ bindings: Binding?...) throws {
    try db.run(sql, bindings)
}
#endif
```

2. In tests, replace direct `store.db` access with `try await store.rawExecute(...)`.

3. Wrap the `tamperedEventBreaksChain` test in SQLiteEventStoreTests in `#if DEBUG` / `#endif` for consistency with Postgres tests.

**Verify:** `swift test --filter SongbirdSQLiteTests`

---

### Task 9: Remove unused `registry` stored property from SQLiteEventStore

The `registry` is stored at init but never read anywhere in the actor. The `InMemoryEventStore` had the same issue fixed in round 5 (parameter kept, storage removed).

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:17,34`

**Changes:**

Remove line 17 (`private let registry: EventTypeRegistry`) and line 34 (`self.registry = registry`). Keep the `registry` parameter in `init` for API compatibility.

**Verify:** `swift build`

---

## Important Issues — Logging & Error Handling

### Task 10: Add logging for dropped/malformed messages in transport layer

Three places in the Distributed module silently drop or close connections without useful diagnostics:

1. `ActorSystemMessageHandler.handleMessage` drops non-call messages silently
2. `MessageFrameDecoder` closes connection on oversized messages with no logging
3. `ServerInboundHandler.channelRead` swallows the actual decode error

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift:233`
- Modify: `Sources/SongbirdDistributed/Transport.swift:225-228,278-279`

**Changes:**

1. In `ActorSystemMessageHandler.handleMessage`, add logging before the early return:
```swift
guard case .call(let call) = message else {
    Self.logger.warning("Server received non-call message, ignoring")
    return
}
```

2. In `MessageFrameDecoder.decode`, add logging before close:
```swift
guard length <= maxWireMessageSize else {
    let logger = Logger(label: "songbird.transport.decoder")
    logger.error("Inbound message exceeds max size", metadata: [
        "size": "\(length)", "max": "\(maxWireMessageSize)"
    ])
    context.close(promise: nil)
    return .needMoreData
}
```

3. In `ServerInboundHandler.channelRead`, include the decode error:
```swift
let message: WireMessage
do {
    message = try JSONDecoder().decode(WireMessage.self, from: Data(bytes))
} catch {
    Self.logger.warning("Failed to decode incoming message, dropping", metadata: [
        "error": "\(error)"
    ])
    return
}
```

**Verify:** `swift build`

---

### Task 11: Add `@unchecked Sendable` documentation to `SongbirdActorSystem`

The class is `@unchecked Sendable` with proper `LockedBox`/`Mutex` protection, but lacks a documentation comment explaining the safety argument (unlike the NIO handlers which have a thorough block comment).

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift:30`

**Changes:** Add a doc comment above the class declaration:

```swift
/// `@unchecked Sendable` is justified because all mutable state (`localActors`,
/// `nextAutoId`, `clients`, `serverBox`) is protected by `LockedBox` (backed by `Mutex`).
/// Every read and write acquires the lock first. The `DistributedActorSystem` protocol
/// requires synchronous (non-`async`) methods, preventing the use of an actor.
public final class SongbirdActorSystem: DistributedActorSystem, @unchecked Sendable {
```

**Verify:** `swift build`

---

### Task 12: Rename `PostgresEventStoreError` and fix misuse in snapshot store

`PostgresSnapshotStore` throws `PostgresEventStoreError.encodingFailed`, which is semantically wrong (the error type name says "EventStore").

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:7-9`
- Modify: `Sources/SongbirdPostgres/PostgresSnapshotStore.swift`

**Changes:**

1. Rename the error enum:
```swift
public enum PostgresStoreError: Error {
    case encodingFailed
    case corruptedTimestamp(String)  // added in Task 2
}
```

2. Update all references from `PostgresEventStoreError` to `PostgresStoreError` (in PostgresEventStore.swift and PostgresSnapshotStore.swift).

**Verify:** `swift build` — check no remaining references to old name.

---

## Important Issues — Hardcoded Values

### Task 13: Remove unused `InMemoryEventStore.init` registry parameter

The parameter is accepted but never stored or used, misleading callers.

**Files:**
- Modify: `Sources/SongbirdTesting/InMemoryEventStore.swift:9`
- Modify: Any test files that pass `registry:` to `InMemoryEventStore`

**Changes:**

Remove the `registry` parameter from `init`:
```swift
public init() {
}
```

Update any call sites that pass `registry:` (search all test files).

**Verify:** `swift build && swift test --filter SongbirdTestingTests`

---

## Test Coverage Gaps

### Task 14: Add missing Distributed module tests

The review found several untested paths:

1. `remoteCallVoid` — no void distributed function test
2. `resignID` — no test that it removes the actor
3. `assignID` — no test for auto-increment naming

**Files:**
- Modify: `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`

**Changes:**

1. Add a `distributed func` that returns `Void` to the test `Greeter` actor:
```swift
distributed func wave() {
    // void function — no return value
}
```

2. Add test for void call:
```swift
@Test func voidDistributedCall() async throws {
    // ... setup server/client systems ...
    try await remoteGreeter.wave()
    // Should not throw — void call succeeded
}
```

3. Add test for resignID:
```swift
@Test func resignIDRemovesActor() async throws {
    let system = SongbirdActorSystem(processName: "test")
    let greeter = Greeter(name: "Alice", actorSystem: system)
    let id = greeter.id

    // Actor should be resolvable
    let resolved: Greeter? = try system.resolve(id: id, as: Greeter.self)
    #expect(resolved != nil)

    // After resignation, should not resolve
    system.resignID(id)
    let afterResign: Greeter? = try system.resolve(id: id, as: Greeter.self)
    #expect(afterResign == nil)
}
```

4. Add test for assignID auto-increment:
```swift
@Test func assignIDAutoIncrements() async throws {
    let system = SongbirdActorSystem(processName: "test")
    let id1 = system.assignID(Greeter.self)
    let id2 = system.assignID(Greeter.self)
    #expect(id1.actorName == "auto-0")
    #expect(id2.actorName == "auto-1")
    #expect(id1.processName == "test")
}
```

**Verify:** `swift test --filter SongbirdDistributedTests`

---

### Task 15: Add missing SQLite test coverage

1. `readCategories` with `maxCount` boundary
2. `verifyChain` with NULL hashes (events before hash chaining)
3. Wrap `tamperedEventBreaksChain` in `#if DEBUG` (done in Task 8)

**Files:**
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Changes:**

```swift
@Test func readCategoriesRespectsMaxCount() async throws {
    let store = try makeStore()
    let s1 = StreamName(category: "account", id: "a")
    let s2 = StreamName(category: "account", id: "b")
    let s3 = StreamName(category: "account", id: "c")
    _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

    let events = try await store.readCategories(["account"], from: 0, maxCount: 2)
    #expect(events.count == 2)
}

#if DEBUG
@Test func verifyChainWithNullHashesTreatsAsValid() async throws {
    let store = try makeStore()
    _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

    // Clear hashes to simulate pre-hash-chain events
    try await store.rawExecute("UPDATE events SET event_hash = NULL")

    let result = try await store.verifyChain()
    #expect(result.intact == true)
    #expect(result.eventsVerified == 2)
}
#endif
```

**Verify:** `swift test --filter SongbirdSQLiteTests`

---

### Task 16: Add missing Hummingbird/Smew test coverage

1. `registerTable` duplicate prevention
2. Multiple projectors in SongbirdServices

**Files:**
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`
- Modify: `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`

**Changes:**

In ReadModelStoreTests:
```swift
@Test func registerTableDeduplicates() async throws {
    let store = try ReadModelStore(storageMode: .inMemory)
    await store.registerTable("users")
    await store.registerTable("users")
    let tables = await store.registeredTables
    #expect(tables == ["users"])
}
```

In SongbirdServicesTests — add a test with multiple projectors:
```swift
@Test func multipleProjectorsReceiveEvents() async throws {
    let store = InMemoryEventStore()
    let pipeline = ProjectionPipeline()
    let projector1 = RecordingProjector(id: "p1")
    let projector2 = RecordingProjector(id: "p2")

    var services = SongbirdServices(eventStore: store, projectionPipeline: pipeline)
    services.registerProjector(projector1)
    services.registerProjector(projector2)

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await services.run() }
        try await Task.sleep(for: .milliseconds(50))

        let event = TestEvent(value: "multi")
        let recorded = try await store.append(event, to: StreamName(category: "test", id: "1"), metadata: EventMetadata(), expectedVersion: nil)
        try await pipeline.enqueue(recorded)
        try await pipeline.waitForIdle()

        #expect(await projector1.appliedEvents.count == 1)
        #expect(await projector2.appliedEvents.count == 1)
        group.cancelAll()
    }
}
```

**Verify:** `swift test --filter SongbirdSmewTests` and `swift test --filter SongbirdHummingbirdTests`

---

## Final Verification

### Task 17: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0032-code-review-remediation-round6.md`

**Steps:**

1. Run `swift build` — verify zero warnings (only pre-existing upstream SwiftNIO warning allowed).
2. Run `swift test --filter 'SongbirdTests|SongbirdTestingTests|SongbirdSQLiteTests|SongbirdDistributedTests|SongbirdHummingbirdTests|SongbirdSmewTests'` — verify all pass.
3. Run `swift test --filter SongbirdPostgresTests` — verify all pass (requires Docker).
4. Write changelog entry documenting all changes.
5. Commit all changes.
