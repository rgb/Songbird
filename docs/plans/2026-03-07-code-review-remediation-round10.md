# Code Review Remediation Round 10 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 18 important issues from a 5-agent parallel code review covering all 7 modules — cancellation safety, precondition guards, concurrency correctness, resource leak prevention, visibility fixes, and high-value test coverage.

**Architecture:** Each task is self-contained. Tasks are independent and can be implemented in any order. The final task does clean build, full test suite, and changelog.

**Tech Stack:** Swift 6.2, Swift Testing, NIOCore, PostgresNIO, Smew/DuckDB

---

## Context

Round 10 found 0 critical, 18 important, 26 suggestions, and 26 test gaps. This plan addresses the highest-impact items: cancellation safety gaps, missing preconditions, concurrency constraint violations, resource leaks, visibility issues, and high-value test coverage.

**Baseline:** 501 tests passing, clean build.

---

### Task 1: Core — InjectorRunner CancellationError + SnapshotPolicy guard

**Why:** `InjectorRunner.run()` catches all errors generically, including `CancellationError`, treating cancellation as an append failure instead of propagating it. Both `GatewayRunner` and `ProcessManagerRunner` have explicit `catch is CancellationError` guards — `InjectorRunner` is the only runner missing this pattern. Also, `SnapshotPolicy.everyNEvents(0)` causes a division-by-zero trap at runtime.

**Files:**
- Modify: `Sources/Songbird/InjectorRunner.swift`
- Modify: `Sources/Songbird/AggregateRepository.swift`

**Changes:**
1. In `InjectorRunner.swift`, read the file first. Find the `do/catch` block inside the `for try await` loop. Add a `catch is CancellationError` before the generic `catch`, matching the pattern in `GatewayRunner.swift` and `ProcessManagerRunner.swift`:
   ```swift
   } catch is CancellationError {
       throw CancellationError()
   } catch {
   ```

2. In `AggregateRepository.swift`, find where `SnapshotPolicy.everyNEvents` is evaluated. The division `(version + 1) / Int64(n)` will trap if `n == 0`. Add a precondition:
   ```swift
   case .everyNEvents(let n):
       precondition(n > 0, "everyNEvents count must be positive")
   ```

**Verify:** `swift build`

**Commit:** `git commit -m "Add CancellationError guard to InjectorRunner and everyNEvents precondition"`

---

### Task 2: Core + Postgres — Add batchSize/maxCount preconditions to consumers

**Why:** Round 9 added `precondition(batchSize > 0)` to `SQLiteEventStore` and `PostgresEventStore`, but the polling consumers that pass `batchSize` to these stores don't validate their own parameter. A `batchSize` of 0 causes `batch.count < batchSize` to always be false, creating infinite loops. Also, `PostgresEventStore.readStream` and `readCategories` are missing `precondition(maxCount > 0)` that the SQLite store has.

**Files:**
- Modify: `Sources/Songbird/EventSubscription.swift`
- Modify: `Sources/Songbird/StreamSubscription.swift`
- Modify: `Sources/Songbird/AggregateStateStream.swift`
- Modify: `Sources/Songbird/ProcessStateStream.swift`
- Modify: `Sources/Songbird/AggregateRepository.swift`
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift`

**Changes:**
1. Add `precondition(batchSize > 0, "batchSize must be positive")` to the `init` of:
   - `EventSubscription`
   - `StreamSubscription`
   - `AggregateStateStream`
   - `ProcessStateStream`
   - `AggregateRepository`

2. In `PostgresEventStore.swift`, add `precondition(maxCount > 0, "maxCount must be positive")` at the top of `readStream` and `readCategories`, matching the SQLite store.

**Verify:** `swift build`

**Commit:** `git commit -m "Add batchSize and maxCount preconditions to subscriptions and Postgres store"`

---

### Task 3: Core — CryptoShreddingStore prefer piiReferenceKey on decrypt

**Why:** On append, the entity ID is stored in `metadata.piiReferenceKey`. On read, `decryptRecord` ignores this and re-derives the entity ID from `streamName`. The metadata field was added precisely for this purpose and should be preferred as the authoritative key lookup reference.

**Files:**
- Modify: `Sources/Songbird/CryptoShreddingStore.swift`

**Changes:**
Read the file first. Find `decryptRecord` and the line that computes `entityId`. Change from:
```swift
let entityId = record.streamName.id ?? record.streamName.description
```
to:
```swift
let entityId = record.metadata.piiReferenceKey ?? record.streamName.id ?? record.streamName.description
```

**Verify:** `swift build && swift test --filter CryptoShreddingStoreTests`

**Commit:** `git commit -m "Prefer piiReferenceKey for key lookup in CryptoShreddingStore decrypt"`

---

### Task 4: Postgres — NotificationSignal cancellation-aware wait

**Why:** `NotificationSignal.wait` uses `withCheckedContinuation` which does not respond to task cancellation. When a subscription task is cancelled while waiting, it blocks for up to `fallbackPollInterval` (default 5s) before the continuation is resumed. This should use `withTaskCancellationHandler` for prompt cancellation.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift`

**Changes:**
Read the file first. Find the `wait(timeout:)` method in `NotificationSignal`. Wrap the existing `withCheckedContinuation` in `withTaskCancellationHandler`:

```swift
func wait(timeout: Duration) async -> Bool {
    let id = UUID()

    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            timeoutTasks[id] = Task {
                try? await Task.sleep(for: timeout)
                self.timeoutWaiter(id: id)
            }
        }
    } onCancel: {
        Task { await self.timeoutWaiter(id: id) }
    }
}
```

Also extract `fallbackPollInterval` default to a named constant in `PostgresDefaults`:
```swift
public static let fallbackPollInterval: Duration = .seconds(5)
```

And update the init parameter default to use it.

**Verify:** `swift build`

**Commit:** `git commit -m "Make NotificationSignal.wait cancellation-aware and extract fallbackPollInterval constant"`

---

### Task 5: Distributed — Fix connect() client leak + LockedBox constraints + arguments visibility

**Why:** Three concurrency/safety issues: (1) Calling `connect()` twice for the same `processName` silently replaces the old `TransportClient` without disconnecting it, leaking the NIO event loop thread. (2) `LockedBox.withLock` doesn't constrain its closure to `@Sendable` or return type to `Sendable`, allowing unsafe escapes. (3) `InvocationEncoder.arguments` has default `internal` visibility.

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift`
- Modify: `Sources/SongbirdDistributed/InvocationEncoder.swift`

**Changes:**
1. In `SongbirdActorSystem.swift`, find the `connect` method. Before assigning the new client, disconnect the old one:
   ```swift
   public func connect(processName: String, socketPath: String) async throws {
       let client = TransportClient()
       try await client.connect(socketPath: socketPath)
       let oldClient = clients.withLock { state -> TransportClient? in
           let old = state[processName]
           state[processName] = client
           return old
       }
       if let oldClient {
           try await oldClient.disconnect()
       }
   }
   ```

2. In the same file, find `LockedBox` and change `withLock` to constrain `@Sendable` and `Sendable`:
   ```swift
   func withLock<R: Sendable>(_ body: @Sendable (inout T) -> R) -> R {
   ```

3. In `InvocationEncoder.swift`, change `var arguments: [Data] = []` to `private var arguments: [Data] = []`.

**Verify:** `swift build && swift test --filter SongbirdDistributed`

**Commit:** `git commit -m "Fix connect() client leak, add Sendable constraints to LockedBox, make arguments private"`

---

### Task 6: Hummingbird — ProjectionFlushMiddleware configurable timeout

**Why:** The middleware calls `pipeline.waitForIdle()` with no timeout parameter, inheriting the 5-second default. This makes the test `returnsResponseEvenWhenPipelineIsNotRunning` take 5+ seconds unnecessarily. A configurable timeout lets tests pass a short duration and lets production code choose an appropriate timeout.

**Files:**
- Modify: `Sources/SongbirdHummingbird/ProjectionFlushMiddleware.swift`
- Modify: `Tests/SongbirdHummingbirdTests/ProjectionFlushMiddlewareTests.swift`

**Changes:**
1. In `ProjectionFlushMiddleware.swift`, read the file first. Add a `timeout` property and init parameter:
   ```swift
   public struct ProjectionFlushMiddleware<Context: RequestContext>: RouterMiddleware {
       let pipeline: ProjectionPipeline
       let timeout: Duration

       public init(pipeline: ProjectionPipeline, timeout: Duration = .seconds(5)) {
           self.pipeline = pipeline
           self.timeout = timeout
       }
   ```
   Update the `handle` method to pass the timeout: `try await pipeline.waitForIdle(timeout: timeout)`

2. In the test file, update the `returnsResponseEvenWhenPipelineIsNotRunning` test to use a short timeout:
   ```swift
   let middleware = ProjectionFlushMiddleware<BasicRequestContext>(
       pipeline: pipeline, timeout: .milliseconds(100)
   )
   ```

**Verify:** `swift build && swift test --filter ProjectionFlushMiddleware`

**Commit:** `git commit -m "Add configurable timeout to ProjectionFlushMiddleware"`

---

### Task 7: Smew — Reduce ReadModelStore.database visibility

**Why:** `ReadModelStore.database` is `public`, giving consumers direct access to create connections that bypass the actor's serial executor isolation. The `connection` is correctly `private`, but the `database` being public undermines the same safety boundary.

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`

**Changes:**
Read the file first. Change `public let database: Database` to `private let database: Database`.

Check if any code outside the module accesses `.database` — search for `readModel.database` or `store.database` across the codebase. If there are external callers, change to `internal` instead of `private` and document the thread-safety implications.

**Verify:** `swift build`

**Commit:** `git commit -m "Reduce ReadModelStore.database visibility to prevent isolation bypass"`

---

### Task 8: SQLite — Fix corruptedRow to 0-based globalPosition + extract column list

**Why:** The `corruptedRow` error reports 1-based DB positions (`autoincPos`) but the public API uses 0-based positions. A developer debugging would look at the wrong row. Also, the same 9-column SELECT list is duplicated across 5 queries.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Changes:**
1. In `SQLiteEventStore.swift`, find `recordedEvent(from:)`. Every `throw SQLiteEventStoreError.corruptedRow(column:globalPosition:)` call uses `autoincPos`. Change all occurrences to use `autoincPos - 1` for consistency with the 0-based public API.

2. Extract the duplicated SELECT column list to a private constant:
   ```swift
   private static let eventColumns = "global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp"
   ```
   Replace all 5 inline column lists (in `readStream`, `readCategories` branches, and `readLastEvent`) with `\(Self.eventColumns)`.

3. Update the corruptedRow test expectations in `SQLiteEventStoreTests.swift` to expect 0-based positions (change `globalPosition: 1` to `globalPosition: 0`).

**Verify:** `swift build && swift test --filter SQLiteEventStoreTests`

**Commit:** `git commit -m "Fix corruptedRow to 0-based globalPosition and extract SELECT column list"`

---

### Task 9: Distributed — Add void-returning and throwing distributed func tests

**Why:** `remoteCallVoid` is never exercised end-to-end (all test actors return values). No test exercises a `distributed func` that throws a domain error, which tests the `WireMessage.error` path. These are low-effort, high-value additions that cover two untested wire paths.

**Files:**
- Modify: `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`

**Changes:**
Read the file first. Find the test `Greeter` actor. Add:
1. A `distributed func ping()` (void-returning)
2. A `distributed func failIfEmpty(name: String) throws -> String` that throws a domain error when name is empty

Add tests:
1. Test that calls `ping()` and succeeds (exercises `remoteCallVoid`)
2. Test that calls `failIfEmpty(name: "")` and catches the error (exercises the error wire path)

**Verify:** `swift test --filter SongbirdDistributed`

**Commit:** `git commit -m "Add void-returning and throwing distributed func tests"`

---

### Task 10: Core + SQLite — High-value test coverage

**Why:** Several important code paths lack test coverage: readStream data round-trip decode, StreamSubscription with batchSize=1, and SQLiteKeyStore deleteKey on non-existent key.

**Files:**
- Test: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`
- Test: `Tests/SongbirdTests/StreamSubscriptionTests.swift`
- Test: `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`

**Changes:**
1. `SQLiteEventStoreTests`: Add a test that appends an event, reads it back via `readStream`, decodes it, and verifies the event data and metadata match.

2. `StreamSubscriptionTests`: Read the existing test file. Add a test using `batchSize: 1` that appends 3+ events and consumes them all, verifying each is delivered correctly.

3. `SQLiteKeyStoreTests`: Add a test that calls `deleteKey` for a reference that never existed and verifies it completes without error.

**Verify:** `swift test --filter "SQLiteEventStoreTests|StreamSubscriptionTests|SQLiteKeyStoreTests"`

**Commit:** `git commit -m "Add readStream round-trip, batchSize=1 subscription, and deleteKey no-op tests"`

---

### Task 11: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0036-code-review-remediation-round10.md`

**Step 1:** `swift build` — clean build, 0 warnings
**Step 2:** `swift test` — all tests pass
**Step 3:** Write changelog summarizing all changes
**Step 4:** Commit: `git commit -m "Add code review remediation round 10 changelog"`

---

## Summary

| Task | Module | Type | Description |
|------|--------|------|-------------|
| 1 | Core | Safety | InjectorRunner CancellationError + SnapshotPolicy guard |
| 2 | Core+Postgres | Safety | batchSize/maxCount preconditions in consumers |
| 3 | Core | Correctness | CryptoShreddingStore prefer piiReferenceKey |
| 4 | Postgres | Concurrency | NotificationSignal cancellation-aware wait |
| 5 | Distributed | Safety | connect() client leak + LockedBox constraints + arguments private |
| 6 | Hummingbird | Performance | ProjectionFlushMiddleware configurable timeout |
| 7 | Smew | Safety | ReadModelStore.database visibility |
| 8 | SQLite | Consistency | corruptedRow 0-based + SELECT column list |
| 9 | Distributed | Test | void-returning and throwing distributed func tests |
| 10 | Core+SQLite | Test | readStream round-trip, batchSize=1, deleteKey no-op |
| 11 | All | Final | Clean build + full test suite + changelog |
