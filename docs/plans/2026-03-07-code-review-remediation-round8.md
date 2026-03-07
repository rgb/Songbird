# Code Review Remediation Round 8 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 10 issues from a 5-agent parallel code review covering all 7 modules, prioritizing consistency gaps, safety improvements, and missing cancellation handling.

**Architecture:** Each task is a self-contained fix with tests. Tasks are independent and can be implemented in any order. The final task does a clean build, full test suite run, and changelog entry.

**Tech Stack:** Swift 6.2, Swift Testing, NIOCore, PostgresNIO, Smew/DuckDB

---

## Context

Round 8 was a comprehensive review with particular focus on Swift 6.2 structured concurrency, lazy implementations, hardcoded values, and test coverage. The review found 1 critical, 19 important, 30 suggestions, and 25 test gaps. This plan addresses the highest-impact issues.

**Baseline:** 490 tests passing, clean build, commit `f07ecef0`.

---

### Task 1: SQLiteEventStore — Replace ISO8601DateFormatter with Date.ISO8601FormatStyle

**Why:** Round 7 (R7-11) replaced `ISO8601DateFormatter` (NSObject, not Sendable) with `Date.ISO8601FormatStyle` (value type, Sendable) in 3 SQLite stores. `SQLiteEventStore` was missed — it still uses the old pattern at line 17. While safe due to the custom executor, it's inconsistent with the other stores.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:17,116`

**Step 1: Remove the ISO8601DateFormatter property**

In `SQLiteEventStore.swift`, delete line 17:
```swift
private let iso8601Formatter = ISO8601DateFormatter()
```

**Step 2: Replace usage in append method**

At line 116, replace:
```swift
let iso8601 = iso8601Formatter.string(from: now)
```
with:
```swift
let iso8601 = now.formatted(.iso8601)
```

**Step 3: Build and run tests**

Run: `swift build && swift test --filter SongbirdSQLiteTests`
Expected: Clean build, all SQLite tests pass.

**Step 4: Commit**
```
git commit -m "Replace ISO8601DateFormatter in SQLiteEventStore for consistency"
```

---

### Task 2: PostgresEventSubscription — Flush position on cancellation

**Why:** Round 7 (R7-8) added position flush on cancellation to core `EventSubscription`. The Postgres variant (`PostgresEventSubscription`) was not updated — it simply returns `nil` on cancellation without saving the last delivered position. This causes unnecessary re-processing on restart.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift:292-295`
- Test: `Tests/SongbirdPostgresTests/PostgresEventSubscriptionTests.swift`

**Step 1: Add position flush before returning nil**

In `PostgresEventSubscription.swift`, replace the cancellation cleanup at lines 292-295:
```swift
        // Cancelled -- clean up LISTEN connection
        await notificationSignal.stop()
        return nil
```
with:
```swift
        // Cancelled -- flush position and clean up LISTEN connection
        if !currentBatch.isEmpty && batchIndex > 0 {
            let lastDeliveredIndex = Swift.min(batchIndex, currentBatch.count) - 1
            let lastDelivered = currentBatch[lastDeliveredIndex].globalPosition
            if lastDelivered > globalPosition {
                try? await positionStore.save(
                    subscriberId: subscriberId,
                    globalPosition: lastDelivered
                )
            }
        }
        await notificationSignal.stop()
        return nil
```

This matches the pattern from core `EventSubscription.swift:177-187`.

**Step 2: Build**

Run: `swift build`
Expected: Clean build.

**Step 3: Commit**
```
git commit -m "Flush position on cancellation in PostgresEventSubscription"
```

---

### Task 3: PostgresEventStore — Remove unused registry field

**Why:** The `registry` field in `PostgresEventStore` is stored in init but never referenced anywhere in the implementation. All encoding/decoding uses `jsonEncoder`/`jsonDecoder` directly. This is dead code left over from an earlier API design.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:16,22-24`

**Step 1: Remove the registry field and init parameter**

In `PostgresEventStore.swift`:

Remove line 16:
```swift
private let registry: EventTypeRegistry
```

At lines 22-24, change the init signature from:
```swift
public init(client: PostgresClient, registry: EventTypeRegistry, notifyChannel: String = "songbird_events") {
    self.client = client
    self.registry = registry
```
to:
```swift
public init(client: PostgresClient, notifyChannel: String = "songbird_events") {
    self.client = client
```

**Step 2: Fix all callers**

Search all test files and source files that call `PostgresEventStore(client:registry:...)` and remove the `registry:` argument. Key locations:
- `Tests/SongbirdPostgresTests/PostgresTestHelper.swift` — the `makeConfiguration`/`withTestClient` helper
- Any other test or source file that constructs a `PostgresEventStore`

**Step 3: Build and run tests**

Run: `swift build && swift test --filter SongbirdPostgresTests`
Expected: Clean build, all Postgres tests pass.

**Step 4: Commit**
```
git commit -m "Remove unused registry field from PostgresEventStore"
```

---

### Task 4: CryptoShreddingStore — Throw on unknown enc: prefix

**Why:** In `decryptField` at line 193-196, if an encrypted string has an `enc:` prefix that doesn't match any known scheme (`enc:pii:`, `enc:ret:`, `enc:pii+ret:`), the method silently returns the raw encrypted string as `.string(encryptedString)`. This could return garbage data to callers. It should throw an error instead.

**Files:**
- Modify: `Sources/Songbird/CryptoShreddingStore.swift:193-196`
- Test: `Tests/SongbirdTests/CryptoShreddingStoreTests.swift`

**Step 1: Add error case**

First check if `CryptoShreddingError` already has an appropriate case. If not, add one:
```swift
case unknownEncryptionScheme(String)
```

**Step 2: Replace silent return with throw**

In `CryptoShreddingStore.swift`, replace lines 193-196:
```swift
        } else {
            // Not an encrypted value — shouldn't happen for protected fields
            return .string(encryptedString)
        }
```
with:
```swift
        } else {
            throw CryptoShreddingError.unknownEncryptionScheme(encryptedString)
        }
```

**Step 3: Add test for unknown prefix**

In `CryptoShreddingStoreTests.swift`, add a test that stores a field value with an unrecognized `enc:` prefix and verifies that reading throws `CryptoShreddingError.unknownEncryptionScheme`. This requires manually inserting a record with an `enc:unknown:...` field value into the inner store, then reading through the `CryptoShreddingStore`.

**Step 4: Build and run tests**

Run: `swift build && swift test --filter CryptoShredding`
Expected: Clean build, all tests pass including new test.

**Step 5: Commit**
```
git commit -m "Throw on unknown enc: prefix in CryptoShreddingStore"
```

---

### Task 5: EncryptedPayload — Make Decodable init unreachable at runtime

**Why:** The `EncryptedPayload.init(from:)` at `JSONValue.swift:121-132` sets `originalEventType = ""` because the type is never decoded from storage — it's always constructed via `init(originalEventType:fields:)`. The empty string is a silent data loss hazard. Since this init exists only for protocol conformance and should never be called, replace the empty string with a `fatalError` or a clear sentinel.

**Files:**
- Modify: `Sources/Songbird/JSONValue.swift:128-131`

**Step 1: Replace empty string with fatalError**

In `JSONValue.swift`, replace lines 128-131:
```swift
        // EncryptedPayload is always constructed via init(originalEventType:fields:).
        // This Decodable path exists only for protocol conformance and lacks the
        // original event type. Callers should not rely on decoding EncryptedPayload.
        self.originalEventType = ""
```
with:
```swift
        // EncryptedPayload is always constructed via init(originalEventType:fields:).
        // If this Decodable path is ever reached, it indicates a programming error.
        preconditionFailure("EncryptedPayload must not be decoded from storage — use init(originalEventType:fields:)")
```

Note: Since `EncryptedPayload` is `internal`, all call sites are within Songbird. We control every code path. This is safe because `CryptoShreddingStore` never decodes `EncryptedPayload` from storage — it decodes raw `[String: JSONValue]` dictionaries.

**Step 2: Build and run tests**

Run: `swift build && swift test --filter CryptoShredding`
Expected: Clean build, all tests pass (no test hits this path).

**Step 3: Commit**
```
git commit -m "Make EncryptedPayload Decodable init unreachable"
```

---

### Task 6: Server-side writeAndFlush — Add promise-based error logging

**Why:** Round 7 (R7-2) added promise-based write error detection for the client-side `TransportClient.sendAndAwaitResponse`. The server-side writes in `SongbirdActorSystem.swift` at lines 275 and 281 still use `channel.writeAndFlush(buffer, promise: nil)`, which silently drops write errors. Server responses are fire-and-forget (no continuation to cancel), but write failures should at least be logged.

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift:272-281`

**Step 1: Add logging for write failures**

Replace the two `writeAndFlush` calls. For the fallback error write at line 275:
```swift
channel.writeAndFlush(buffer, promise: nil)
```
becomes:
```swift
let p1 = channel.eventLoop.makePromise(of: Void.self)
p1.futureResult.whenFailure { err in
    Self.logger.error("Failed to write error response", metadata: ["error": "\(err)"])
}
channel.writeAndFlush(buffer, promise: p1)
```

For the main response write at line 281:
```swift
channel.writeAndFlush(buffer, promise: nil)
```
becomes:
```swift
let p2 = channel.eventLoop.makePromise(of: Void.self)
p2.futureResult.whenFailure { err in
    Self.logger.error("Failed to write response", metadata: ["error": "\(err)"])
}
channel.writeAndFlush(buffer, promise: p2)
```

**Step 2: Build**

Run: `swift build`
Expected: Clean build.

**Step 3: Commit**
```
git commit -m "Add promise-based write error logging for server-side responses"
```

---

### Task 7: ReadModelStore.rebuild — Add Task.checkCancellation

**Why:** The `rebuild` method at `ReadModelStore.swift:328-344` processes events in batches but never checks for cancellation. A rebuild of a large read model could take a long time, and without cancellation checks the task would not respond to cancellation requests until the entire rebuild completes.

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift:333-334`

**Step 1: Add cancellation check at the top of the while loop**

In `ReadModelStore.swift`, after line 333 (`while true {`), add:
```swift
try Task.checkCancellation()
```

So it becomes:
```swift
        while true {
            try Task.checkCancellation()
            let batch = try await store.readAll(from: position, maxCount: batchSize)
```

**Step 2: Build**

Run: `swift build`
Expected: Clean build.

**Step 3: Commit**
```
git commit -m "Add Task.checkCancellation to ReadModelStore.rebuild"
```

---

### Task 8: Extract duplicated hardcoded constants

**Why:** Several values are duplicated across multiple locations:
- `"genesis"` hash seed: `SQLiteEventStore.swift:128,247` and `PostgresEventStore.swift:70,269`
- `"songbird_events"` NOTIFY channel default: `PostgresEventStore.swift:22`, `PostgresEventSubscription.swift:21,93,148`
- `"lake"` cold schema default: `DuckLakeConfig.swift:45` and `ReadModelStore.swift:58`

Extracting these removes the risk of them drifting out of sync.

**Files:**
- Modify: `Sources/Songbird/EventStore.swift` (or appropriate shared location)
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift`
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift`
- Modify: `Sources/SongbirdSmew/DuckLakeConfig.swift`
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`

**Step 1: Add genesis hash seed constant**

In `Sources/Songbird/EventStore.swift` (or a similar shared location in the core module), add:
```swift
/// The initial hash value used as the seed for the first event in a hash chain.
/// Both SQLite and Postgres event stores must use this same value.
public enum HashChain {
    public static let genesisSeed = "genesis"
}
```

Then replace all 4 occurrences of the literal `"genesis"` in `SQLiteEventStore.swift` and `PostgresEventStore.swift` with `HashChain.genesisSeed`.

**Step 2: Extract NOTIFY channel default**

In `PostgresEventStore.swift`, add a public constant:
```swift
public enum PostgresDefaults {
    public static let notifyChannel = "songbird_events"
}
```

Then replace the default parameter values in `PostgresEventStore.init` and `NotificationSignal.start`/`reconnect` and `PostgresEventSubscription.init` to use `PostgresDefaults.notifyChannel`.

**Step 3: Extract cold schema default**

In `DuckLakeConfig.swift`, add:
```swift
public enum DuckLakeDefaults {
    public static let schemaName = "lake"
}
```

Then use it in `DuckLakeConfig.init(... schemaName: String = DuckLakeDefaults.schemaName)` and in `ReadModelStore.init` where it falls back to `"lake"`.

**Step 4: Build and run tests**

Run: `swift build && swift test`
Expected: Clean build, all 490 tests pass.

**Step 5: Commit**
```
git commit -m "Extract duplicated hardcoded constants (genesis, notify channel, lake schema)"
```

---

### Task 9: Add EventSubscription cancellation flush verification test

**Why:** R7-8 added position flushing on cancellation to `EventSubscription`, but there's no test verifying the flushed position is actually persisted. This test confirms that when a subscription is cancelled mid-batch, the position of the last delivered event is saved.

**Files:**
- Test: `Tests/SongbirdTests/EventSubscriptionTests.swift`

**Step 1: Write the test**

```swift
@Test func cancellationFlushesLastDeliveredPosition() async throws {
    let store = InMemoryEventStore()
    let positionStore = InMemoryPositionStore()
    let registry = EventTypeRegistry()
    registry.register(TestEvent.self)

    // Append several events
    for i in 0..<5 {
        _ = try await store.append(
            TestEvent(name: "event-\(i)"),
            to: StreamName(category: "test", id: "1"),
            metadata: EventMetadata()
        )
    }

    let subscription = EventSubscription(
        subscriberId: "flush-test",
        categories: ["test"],
        store: store,
        positionStore: positionStore,
        batchSize: 10,
        tickInterval: .seconds(60) // long tick so it won't poll again
    )

    // Consume 3 events then cancel
    var consumed = 0
    let task = Task {
        for try await _ in subscription {
            consumed += 1
            if consumed == 3 {
                // Cancel after consuming 3 events
                throw CancellationError()
            }
        }
    }

    // Wait for the task to finish
    do {
        try await task.value
    } catch is CancellationError {
        // Expected
    } catch {
        // Also acceptable — cancellation may surface differently
    }

    // The position store should have saved the position of the 3rd event consumed
    let savedPosition = try await positionStore.load(subscriberId: "flush-test")
    #expect(savedPosition != nil, "Position should be saved on cancellation")
    // Position should be >= 2 (0-based global position of 3rd event)
    if let pos = savedPosition {
        #expect(pos >= 2, "Position should reflect at least 3 events consumed")
    }
}
```

**Step 2: Run test**

Run: `swift test --filter EventSubscriptionTests`
Expected: All tests pass.

**Step 3: Commit**
```
git commit -m "Add EventSubscription cancellation flush verification test"
```

---

### Task 10: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0034-code-review-remediation-round8.md`

**Step 1: Clean build**

Run: `swift build`
Expected: Clean build with 0 warnings, 0 errors.

**Step 2: Full test suite**

Run: `swift test`
Expected: All tests pass (490 + new tests from tasks above).

**Step 3: Write changelog**

Create `changelog/0034-code-review-remediation-round8.md` summarizing all changes from this plan.

**Step 4: Commit**
```
git commit -m "Add code review remediation round 8 changelog"
```

---

## Summary

| Task | Module | Type | Description |
|------|--------|------|-------------|
| 1 | SQLite | Consistency | Replace ISO8601DateFormatter in SQLiteEventStore |
| 2 | Postgres | Safety | Flush position on cancellation in PostgresEventSubscription |
| 3 | Postgres | Cleanup | Remove unused registry field from PostgresEventStore |
| 4 | Core | Safety | Throw on unknown enc: prefix in CryptoShreddingStore |
| 5 | Core | Safety | Make EncryptedPayload Decodable init unreachable |
| 6 | Distributed | Observability | Add write error logging for server-side responses |
| 7 | Smew | Concurrency | Add Task.checkCancellation to ReadModelStore.rebuild |
| 8 | Cross-cutting | Cleanup | Extract duplicated hardcoded constants |
| 9 | Core | Test | Add EventSubscription cancellation flush test |
| 10 | All | Final | Clean build + full test suite + changelog |
