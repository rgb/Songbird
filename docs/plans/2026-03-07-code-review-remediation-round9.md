# Code Review Remediation Round 9 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 12 issues from a 5-agent parallel code review covering all 7 modules — cleanup of dead code, missing guards, visibility fixes, consistency gaps, and high-value test coverage.

**Architecture:** Each task is self-contained. Tasks are independent and can be implemented in any order. The final task does clean build, full test suite, and changelog.

**Tech Stack:** Swift 6.2, Swift Testing, NIOCore, PostgresNIO, Smew/DuckDB

---

## Context

Round 9 found 0 critical, 27 important, 31 suggestions, and 41 test gaps. This plan addresses the highest-impact items: dead code removal, infinite loop prevention, compile-time safety improvements, consistency fixes, and misleading documentation.

**Baseline:** 492 tests passing, clean build.

---

### Task 1: SQLiteEventStore — Remove unused `registry` parameter

**Why:** Round 8 removed the unused `registry` field from `PostgresEventStore`. The same dead parameter exists in `SQLiteEventStore.init` — it's accepted but never stored or used, creating a false API contract.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:25`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Changes:**
1. In `SQLiteEventStore.swift`, remove the `registry` parameter from init:
   ```swift
   // Before:
   public init(path: String, registry: EventTypeRegistry) throws {
   // After:
   public init(path: String) throws {
   ```

2. Find and fix ALL callers — search the entire project for `SQLiteEventStore(` and remove the `registry:` argument. Key locations:
   - `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift` — the helper that creates the store
   - Any demo app files

**Verify:** `swift build && swift test --filter SongbirdSQLiteTests`

**Commit:** `git commit -m "Remove unused registry parameter from SQLiteEventStore"`

---

### Task 2: SQLiteEventStore — Guard against invalid batchSize and maxCount

**Why:** `verifyChain(batchSize: 0)` causes an infinite loop (LIMIT 0 returns 0 rows, termination condition `0 < 0` is false). Negative `maxCount` in `readStream`/`readCategories` passes `LIMIT -1` to SQLite which means "no limit", loading all events into memory.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Test: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Changes:**
1. Add a precondition at the top of `verifyChain`:
   ```swift
   precondition(batchSize > 0, "batchSize must be positive")
   ```

2. Add preconditions at the top of `readStream` and `readCategories`:
   ```swift
   precondition(maxCount > 0, "maxCount must be positive")
   ```

3. Also add the same `batchSize` guard to `PostgresEventStore.verifyChain` for consistency — read that file and add the same precondition.

**Verify:** `swift build`

**Commit:** `git commit -m "Guard against invalid batchSize and maxCount in event stores"`

---

### Task 3: SQLite stores — Make `db` property private

**Why:** All 4 SQLite actors declare `nonisolated(unsafe) let db: Connection` with default `internal` visibility. Any code within the module can bypass actor isolation by accessing `db` directly. Making it `private` enforces the safety guarantee at compile time.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:16`
- Modify: `Sources/SongbirdSQLite/SQLitePositionStore.swift:10`
- Modify: `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift:18`
- Modify: `Sources/SongbirdSQLite/SQLiteKeyStore.swift:19`

**Changes:**
In each file, change:
```swift
nonisolated(unsafe) let db: Connection
```
to:
```swift
private nonisolated(unsafe) let db: Connection
```

**Verify:** `swift build`

**Commit:** `git commit -m "Make db property private in all SQLite stores"`

---

### Task 4: PostgresEventSubscription — Use SubscriptionDefaults.batchSize

**Why:** Every subscription type in the codebase uses `SubscriptionDefaults.batchSize` as the default except `PostgresEventSubscription`, which hardcodes `100`. If someone changes the default, this subscription would silently keep the old value.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift:146`

**Changes:**
Change the init parameter default from:
```swift
batchSize: Int = 100,
```
to:
```swift
batchSize: Int = SubscriptionDefaults.batchSize,
```

This requires `import Songbird` which should already be present (check).

**Verify:** `swift build`

**Commit:** `git commit -m "Use SubscriptionDefaults.batchSize in PostgresEventSubscription"`

---

### Task 5: Distributed — Remove unused targetName field + use wrapping addition

**Why:** `InvocationEncoder.targetName` is declared, initialized to `""`, but never written to or read from — dead code. Also, `TransportClient.nextRequestId += 1` will trap on `UInt64.max` in debug builds; wrapping addition makes the intent explicit.

**Files:**
- Modify: `Sources/SongbirdDistributed/InvocationEncoder.swift:12`
- Modify: `Sources/SongbirdDistributed/Transport.swift:96`

**Changes:**
1. In `InvocationEncoder.swift`, remove the `targetName` property:
   ```swift
   // Delete this line:
   var targetName: String = ""
   ```

2. In `Transport.swift`, change:
   ```swift
   nextRequestId += 1
   ```
   to:
   ```swift
   nextRequestId &+= 1
   ```

**Verify:** `swift build`

**Commit:** `git commit -m "Remove unused targetName field and use wrapping addition for requestId"`

---

### Task 6: SongbirdServices — Fix misleading doc comments

**Why:** The doc comment on `SongbirdServices` shows usage with `Application(router: router, services: [services])` and `app.runService()`, but `SongbirdServices` does not conform to any `Service` protocol. This code would not compile as written.

**Files:**
- Modify: `Sources/SongbirdHummingbird/SongbirdServices.swift:27-41`

**Changes:**
Replace the doc comment's usage example to match the actual usage pattern:
```swift
/// ```swift
/// var services = SongbirdServices(
///     eventStore: store,
///     projectionPipeline: pipeline,
///     positionStore: positionStore,
///     eventRegistry: registry
/// )
/// services.registerProjector(balanceProjector)
/// services.registerProcessManager(FulfillmentPM.self, tickInterval: .seconds(1))
///
/// let serviceTask = Task { try await services.run() }
///
/// // Later: cancel stops all services
/// serviceTask.cancel()
/// ```
```

Remove the references to `Application(router:services:)` and `app.runService()`.

**Verify:** `swift build`

**Commit:** `git commit -m "Fix misleading SongbirdServices doc comment"`

---

### Task 7: ReadModelStore — Replace precondition with guard in tierProjections

**Why:** `tierProjections(olderThan:)` uses `precondition(thresholdDays > 0)` which crashes the process in production. Since this can be called from a background `TieringService`, a misconfiguration would kill the entire application.

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`

**Changes:**
Find the `tierProjections` method. Replace:
```swift
precondition(thresholdDays > 0, "thresholdDays must be positive")
```
with:
```swift
guard thresholdDays > 0 else { return 0 }
```

This silently returns 0 rows tiered for invalid input, matching the behavior of the `guard isTiered else { return 0 }` check that precedes it.

**Verify:** `swift build`

**Commit:** `git commit -m "Replace precondition with guard in tierProjections"`

---

### Task 8: Extract duplicated hash computation helper

**Why:** The hash input format and SHA256 hex-string computation is duplicated between `append` and `verifyChain` in both SQLiteEventStore and PostgresEventStore. If the format ever changes, both locations must be updated or chain verification breaks.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift`

**Changes:**
1. In `SQLiteEventStore.swift`, extract a private static helper:
   ```swift
   private static func computeEventHash(
       previousHash: String, eventType: String,
       streamName: String, data: String, timestamp: String
   ) -> String {
       let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(data)\0\(timestamp)"
       return SHA256.hash(data: Data(hashInput.utf8))
           .map { String(format: "%02x", $0) }
           .joined()
   }
   ```
   Then replace both inline hash computations (in `append` and `verifyChain`) with calls to this helper.

2. Do the same in `PostgresEventStore.swift` — extract the identical helper and replace the two inline computations.

**Verify:** `swift build && swift test --filter "SQLiteEventStoreTests|PostgresChainVerification"`

**Commit:** `git commit -m "Extract duplicated hash computation into shared helper"`

---

### Task 9: Distributed — Add Equatable to SongbirdDistributedError + fix test assertions

**Why:** All distributed tests use `#expect(throws: SongbirdDistributedError.self)` which only checks the error type, not the specific case. A test expecting `.notConnected` would also pass if `.remoteCallFailed` were thrown.

**Files:**
- Modify: `Sources/SongbirdDistributed/WireProtocol.swift`
- Modify: `Tests/SongbirdDistributedTests/TransportTests.swift`
- Modify: `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`

**Changes:**
1. Add `Equatable` conformance to `SongbirdDistributedError`:
   ```swift
   public enum SongbirdDistributedError: Error, Equatable {
   ```
   (The enum has associated `String` values which are auto-Equatable.)

2. Update test assertions to check specific error cases. For example:
   - `callBeforeConnectThrowsNotConnected` should check for `.notConnected`
   - Timeout tests should check for `.remoteCallFailed` with timeout message

**Verify:** `swift build && swift test --filter SongbirdDistributed`

**Commit:** `git commit -m "Add Equatable to SongbirdDistributedError and fix test assertions"`

---

### Task 10: SQLite stores — Add corruptedRow error path tests

**Why:** The `recordedEvent(from:)` helper in SQLiteEventStore has 10 `corruptedRow` error paths, none tested. SQLiteSnapshotStore and SQLiteKeyStore also have untested corruptedRow paths. These are the error paths that protect against silent data corruption.

**Files:**
- Test: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`
- Test: `Tests/SongbirdSQLiteTests/SQLiteSnapshotStoreTests.swift`
- Test: `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`

**Changes:**
Use `rawExecute` (available in `#if DEBUG` builds) to insert rows with NULL or invalid data in required columns, then verify that reads throw the correct error type.

Add at least:
1. `SQLiteEventStoreTests`: Test that a row with NULL `event_type` throws `SQLiteEventStoreError.corruptedRow`
2. `SQLiteSnapshotStoreTests`: Test that a row with NULL `state` blob throws `SQLiteSnapshotStoreError.corruptedRow`
3. `SQLiteKeyStoreTests`: Test that a row with NULL `key_data` throws `SQLiteKeyStoreError.corruptedRow`

**Verify:** `swift test --filter SongbirdSQLiteTests`

**Commit:** `git commit -m "Add corruptedRow error path tests for SQLite stores"`

---

### Task 11: Core — Add AggregateRepository load batching test

**Why:** The `load` method reads events in batches of `batchSize` (default 1000) with `Task.checkCancellation()` in the loop. No test exercises the batching behavior — all tests use default batch size larger than the test data.

**Files:**
- Test: `Tests/SongbirdTests/AggregateRepositoryTests.swift`

**Changes:**
Add a test that creates an aggregate with 5+ events and loads it with `batchSize: 2`, verifying the final state is correct (proving all batches were folded). Use the existing test aggregate type from the file.

**Verify:** `swift test --filter AggregateRepositoryTests`

**Commit:** `git commit -m "Add AggregateRepository load batching test"`

---

### Task 12: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0035-code-review-remediation-round9.md`

**Step 1:** `swift build` — clean build, 0 warnings
**Step 2:** `swift test` — all tests pass
**Step 3:** Write changelog summarizing all changes
**Step 4:** Commit: `git commit -m "Add code review remediation round 9 changelog"`

---

## Summary

| Task | Module | Type | Description |
|------|--------|------|-------------|
| 1 | SQLite | Cleanup | Remove unused registry parameter from SQLiteEventStore |
| 2 | SQLite+Postgres | Safety | Guard against invalid batchSize/maxCount |
| 3 | SQLite | Safety | Make `db` property private in all 4 stores |
| 4 | Postgres | Consistency | Use SubscriptionDefaults.batchSize |
| 5 | Distributed | Cleanup | Remove dead targetName + wrapping addition |
| 6 | Hummingbird | Docs | Fix misleading SongbirdServices doc comment |
| 7 | Smew | Safety | Replace precondition with guard in tierProjections |
| 8 | SQLite+Postgres | DRY | Extract duplicated hash computation helper |
| 9 | Distributed | Quality | Add Equatable to error type + fix test assertions |
| 10 | SQLite | Test | Add corruptedRow error path tests |
| 11 | Core | Test | Add AggregateRepository load batching test |
| 12 | All | Final | Clean build + full test suite + changelog |
