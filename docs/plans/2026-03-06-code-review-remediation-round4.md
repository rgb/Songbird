# Code Review Remediation (Round 4) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all remaining issues from the fourth comprehensive code review: 4 critical, 14 important, 4 suggestions, and 9 test gaps.

**Architecture:** Fixes are grouped into 22 tasks ordered by severity: critical concurrency/correctness bugs first, then safety/consistency issues, then improvements, then test gaps. Tasks that touch the same file are merged. Independent tasks can be parallelized.

**Tech Stack:** Swift 6.2, Swift Testing, SQLite.swift, PostgresNIO, NIOCore, NIOPosix, Smew (DuckDB), swift-metrics, swift-log, Hummingbird

---

## Task 1: Critical — Fix dictionary mutation during iteration in NotificationSignal

**Severity:** Critical — mutating a dictionary inside a `for-in` loop over it is undefined behavior in Swift.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift:40-45, 72-77`

**Step 1: Fix `notifyWaiters()`**

Replace lines 40-45:

```swift
private func notifyWaiters() {
    let pending = waiters
    waiters.removeAll()
    for (_, continuation) in pending {
        continuation.resume(returning: true)
    }
}
```

**Step 2: Fix `stop()`**

Replace lines 72-83:

```swift
func stop() async {
    listenTask?.cancel()
    let pending = waiters
    waiters.removeAll()
    for (_, continuation) in pending {
        continuation.resume(returning: false)
    }
    if let connection {
        try? await connection.close()
    }
    self.connection = nil
    self.listenTask = nil
}
```

**Step 3: Verify build**

Run: `swift build --target SongbirdPostgres 2>&1 | tail -3`
Expected: Build complete

**Step 4: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -10`
Expected: All tests pass

**Step 5: Commit**

```
fix: drain waiters dictionary before iterating in NotificationSignal
```

---

## Task 2: Critical — Fix readCategories index bypass in SQLiteEventStore

**Severity:** Critical — `(global_position - 1) >= ?` expression prevents SQLite from using the `idx_events_category` index, causing full table scans.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:187-211`

**Step 1: Fix the queries to shift the parameter instead of the column**

The fix is to pass `globalPosition + 1` to the query and compare against the raw `global_position` column, so the index is usable. The `recordedEvent(from:)` method already subtracts 1, so read consumers still see 0-based positions.

In `readCategories`, replace the empty-categories path (around line 190):

```swift
WHERE global_position >= ?
```

And bind `globalPosition + 1` instead of `globalPosition`.

Same for the single-category path (around line 198):

```swift
WHERE stream_category = ? AND global_position >= ?
```

And bind `globalPosition + 1`.

Same for the multi-category path (around line 208):

```swift
WHERE stream_category IN (\(placeholders)) AND global_position >= ?
```

And bind `globalPosition + 1`.

Read the file first to find the exact current SQL text, then replace each `(global_position - 1) >= ?` with `global_position >= ?` and change the bind value from `globalPosition` to `globalPosition + 1`.

**Step 2: Run tests**

Run: `swift test --filter SongbirdSQLiteTests 2>&1 | tail -10`
Expected: All tests pass (behavior is identical, just more index-friendly)

**Step 3: Commit**

```
perf: fix readCategories to use index-friendly WHERE clause
```

---

## Task 3: Critical — Fix cancelPendingCall error type for external cancellation

**Severity:** Critical — external task cancellation produces `remoteCallFailed("Call timed out")` instead of `CancellationError`.

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:147-157`

**Step 1: Add error parameter to cancelPendingCall**

Replace lines 152-157:

```swift
/// Cancels a pending call by resuming its continuation with the given error.
private func cancelPendingCall(requestId: UInt64, error: any Error) {
    if let continuation = pendingCalls.removeValue(forKey: requestId) {
        continuation.resume(throwing: error)
    }
}
```

**Step 2: Update the onCancel handler (line 148) to pass CancellationError**

```swift
} onCancel: {
    Task { await self.cancelPendingCall(requestId: requestId, error: CancellationError()) }
}
```

**Step 3: Find the timeout task that also calls cancelPendingCall**

Search for the other call site (in `sendAndAwaitResponse`, the timeout task). Update it to pass the timeout error:

```swift
Task { await self.cancelPendingCall(requestId: requestId, error: SongbirdDistributedError.remoteCallFailed("Call timed out")) }
```

Also update the `Task.isCancelled` check (around line 141-144) — it already resumes with `CancellationError()`, so that's correct. Just make sure the `disconnect()` method's calls also pass an appropriate error.

Read `disconnect()` and update its calls to `cancelPendingCall` if it uses the old no-parameter signature. It likely directly resumes continuations, so it may not need changes.

**Step 4: Run tests**

Run: `swift test --filter TransportTests 2>&1 | tail -10`
Expected: All tests pass (timeout test still gets SongbirdDistributedError)

**Step 5: Commit**

```
fix: distinguish cancellation from timeout in cancelPendingCall
```

---

## Task 4: Critical — Log response encode failure in ActorSystemMessageHandler

**Severity:** Critical — silent `return` on encode failure leaves client hanging indefinitely.

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift:251`

**Step 1: Read the file to find the exact context around line 251**

**Step 2: Replace the silent guard with logged fallback**

Replace:
```swift
guard let responseData = try? JSONEncoder().encode(response) else { return }
```

With:
```swift
let responseData: Data
do {
    responseData = try JSONEncoder().encode(response)
} catch {
    Self.logger.error("Failed to encode response", metadata: [
        "requestId": "\(call.requestId)",
        "error": "\(error)",
    ])
    // Send an error response so the client doesn't hang
    let fallback = WireMessage.error(.init(
        requestId: call.requestId,
        message: "Internal: response encoding failed"
    ))
    if let fallbackData = try? JSONEncoder().encode(fallback) {
        var buffer = channel.allocator.buffer(capacity: fallbackData.count)
        buffer.writeBytes(fallbackData)
        channel.writeAndFlush(buffer, promise: nil)
    }
    return
}
```

Check if there's a `logger` or `Self.logger` available in the handler. If not, add one following the pattern from `ServerInboundHandler` (which already has a static logger).

**Step 3: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```
fix: log and send fallback error when response encoding fails
```

---

## Task 5: Important — ProcessManagerRunner error isolation

**Severity:** Important — unlike GatewayRunner, errors from `processEvent` kill the entire runner.

**Files:**
- Modify: `Sources/Songbird/ProcessManagerRunner.swift:71-73`

**Step 1: Wrap processEvent in error isolation**

Replace lines 71-73:

```swift
for try await event in subscription {
    do {
        try await processEvent(event)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        logger.error("Process manager event handling failed",
            metadata: [
                "process_id": "\(PM.processId)",
                "event_type": "\(event.eventType)",
                "error": "\(error)",
            ])
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter ProcessManagerRunnerTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
fix: isolate ProcessManagerRunner errors to match GatewayRunner pattern
```

---

## Task 6: Important — Fix verifyChain brokenAtSequence consistency

**Severity:** Important — `verifyChain` returns 1-based `brokenAtSequence` but all other API methods return 0-based `globalPosition`.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:278-282`
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:274-279`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift` (update assertion)
- Modify: `Tests/SongbirdPostgresTests/PostgresChainVerificationTests.swift` (update assertion)

**Step 1: Fix SQLite verifyChain**

In `SQLiteEventStore.swift`, find the `brokenAtSequence: globalPos` line and change to:

```swift
brokenAtSequence: globalPos - 1
```

**Step 2: Fix Postgres verifyChain**

In `PostgresEventStore.swift`, find the `brokenAtSequence: globalPos` line and change to:

```swift
brokenAtSequence: globalPos - 1
```

**Step 3: Update test assertions**

In `SQLiteEventStoreTests.swift`, find `tamperedEventBreaksChain` and change:
```swift
#expect(result.brokenAtSequence == 1)  // was 2 (0-based: row 2 is position 1)
```

In `PostgresChainVerificationTests.swift`, find `tamperedEventBreaksChain` and change:
```swift
#expect(result.brokenAtSequence == 1)  // was 2
```

**Step 4: Run tests**

Run: `swift test --filter SQLiteEventStoreTests 2>&1 | tail -5` and `swift test --filter PostgresChainVerificationTests 2>&1 | tail -5`
Expected: All pass

**Step 5: Commit**

```
fix: make verifyChain brokenAtSequence 0-based consistent with globalPosition
```

---

## Task 7: Important — Fix PostgresEventStore.append timestamp

**Severity:** Important — returned RecordedEvent uses `Date()` not the DB-normalized timestamp from the RETURNING clause.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:33, 71-77, 124-133`

**Step 1: Parse the normalized timestamp from RETURNING and use it**

After the `for try await` loop (line 73-77), add a guard for the normalizedTimestamp and parse it to a Date. Then use that parsed date in the returned RecordedEvent instead of `now`.

Read the file first for exact context. The changes:
1. Add a `var returnedTimestamp: Date = now` before the transaction.
2. Inside the loop after `normalizedTimestamp = ts`, parse it: `returnedTimestamp = iso8601Formatter.date(from: ts) ?? now`
3. In the returned RecordedEvent (line 132), use `returnedTimestamp` instead of `now`.

You'll need to check if `PostgresEventStore` has an `iso8601Formatter` property. If not, create an `ISO8601DateFormatter` instance. Since `PostgresEventStore` is a struct (not an actor), you can use a local formatter or a static one.

**Step 2: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -10`
Expected: All pass

**Step 3: Commit**

```
fix: use DB-normalized timestamp in returned RecordedEvent
```

---

## Task 8: Important — Add ClientInboundHandler channelInactive/errorCaught

**Severity:** Important — pending calls hang 30s on unexpected server disconnect.

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:276-298`

**Step 1: Read the full Transport.swift to understand the disconnect() pattern**

**Step 2: Add a handleDisconnect method to TransportClient**

Add a method that drains pending calls with a disconnect error (similar to what `disconnect()` does):

```swift
/// Called when the channel closes unexpectedly.
func handleUnexpectedDisconnect() {
    for (_, continuation) in pendingCalls {
        continuation.resume(throwing: SongbirdDistributedError.notConnected("connection lost"))
    }
    pendingCalls.removeAll()
    channel = nil
}
```

**Step 3: Add channelInactive and errorCaught to ClientInboundHandler**

```swift
func channelInactive(context: ChannelHandlerContext) {
    Task {
        await client.handleUnexpectedDisconnect()
    }
    context.fireChannelInactive()
}

func errorCaught(context: ChannelHandlerContext, error: Error) {
    Self.logger.warning("Channel error", metadata: ["error": "\(error)"])
    context.close(promise: nil)
}
```

**Step 4: Run tests**

Run: `swift test --filter TransportTests 2>&1 | tail -10`
Expected: All pass

**Step 5: Commit**

```
fix: handle unexpected disconnect in ClientInboundHandler
```

---

## Task 9: Important — Fix PostgresEventStore.verifyChain O(N²) pagination

**Severity:** Important — OFFSET-based pagination is O(N²) for large event stores.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:250-293`

**Step 1: Replace OFFSET pagination with cursor-based**

Replace the `while true` loop to use `WHERE global_position > lastSeen` instead of `OFFSET`:

```swift
public func verifyChain(batchSize: Int = 1000) async throws -> ChainVerificationResult {
    var previousHash = "genesis"
    var verified = 0
    var lastGlobalPosition: Int64 = 0  // BIGSERIAL starts at 1, so 0 means "before first"

    while true {
        let rows = try await client.query("""
            SELECT global_position, event_type, stream_name, data::text, to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), event_hash
            FROM events
            WHERE global_position > \(lastGlobalPosition)
            ORDER BY global_position ASC
            LIMIT \(batchSize)
            """)

        var batchCount = 0
        for try await (globalPos, eventType, streamName, dataStr, timestamp, storedHash)
            in rows.decode((Int64, String, String, String, String, String?).self)
        {
            batchCount += 1
            lastGlobalPosition = globalPos

            let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(dataStr)\0\(timestamp)"
            let computedHash = SHA256.hash(data: Data(hashInput.utf8))
                .map { String(format: "%02x", $0) }
                .joined()

            if let storedHash, storedHash != computedHash {
                return ChainVerificationResult(
                    intact: false,
                    eventsVerified: verified,
                    brokenAtSequence: globalPos - 1  // 0-based (includes Task 6 fix)
                )
            }

            previousHash = storedHash ?? computedHash
            verified += 1
        }

        if batchCount < batchSize { break }
        await Task.yield()
    }

    return ChainVerificationResult(intact: true, eventsVerified: verified)
}
```

**Step 2: Run tests**

Run: `swift test --filter PostgresChainVerificationTests 2>&1 | tail -5`
Expected: All pass

**Step 3: Commit**

```
perf: use cursor-based pagination in PostgresEventStore.verifyChain
```

---

## Task 10: Important — Wire retention Duration through to KeyStore

**Severity:** Important — `FieldProtection.retention(Duration)` accepts Duration but never passes it to KeyStore.

**Files:**
- Modify: `Sources/Songbird/KeyStore.swift:9` (add `expiresAfter` parameter)
- Modify: `Sources/Songbird/CryptoShreddingStore.swift:63-64, 70` (pass Duration)
- Modify: `Sources/SongbirdTesting/InMemoryKeyStore.swift` (conform to new signature)
- Modify: `Sources/SongbirdSQLite/SQLiteKeyStore.swift` (conform, store expires_at)
- Modify: `Sources/SongbirdPostgres/PostgresKeyStore.swift` (conform, store expires_at)

**Step 1: Read all files first to understand the current protocol and implementations**

**Step 2: Add optional expiresAfter parameter to KeyStore.key(for:layer:)**

```swift
public protocol KeyStore: Sendable {
    func key(for reference: String, layer: KeyLayer, expiresAfter: Duration?) async throws -> SymmetricKey
    func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey?
    func deleteKey(for reference: String, layer: KeyLayer) async throws
    func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool
}
```

Add a default extension so existing callers don't break:

```swift
extension KeyStore {
    public func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey {
        try await key(for: reference, layer: layer, expiresAfter: nil)
    }
}
```

**Step 3: Update CryptoShreddingStore.append to pass Duration**

In the `switch level` block:

```swift
case .retention(let duration):
    let retKey = try await keyStore.key(for: entityId, layer: .retention, expiresAfter: duration)
    // ...

case .piiAndRetention(let duration):
    let piiKey = try await keyStore.key(for: entityId, layer: .pii)
    let retKey = try await keyStore.key(for: entityId, layer: .retention, expiresAfter: duration)
    // ...
```

**Step 4: Update InMemoryKeyStore, SQLiteKeyStore, PostgresKeyStore**

- **InMemoryKeyStore**: Accept `expiresAfter` parameter, ignore it (in-memory keys don't expire — tests delete them manually).
- **SQLiteKeyStore**: Accept `expiresAfter` parameter. If non-nil, compute `expires_at = Date() + duration` and store in the `expires_at` column. The schema already has this column.
- **PostgresKeyStore**: Same pattern — store `expires_at` in the column if provided.

Read each file first to understand the current INSERT SQL and adapt.

**Step 5: Run tests**

Run: `swift test 2>&1 | tail -20`
Expected: All pass

**Step 6: Commit**

```
feat: wire retention Duration through to KeyStore expires_at
```

---

## Task 11: Important — Remove duplicate WireProtocol tests

**Severity:** Important — 3 tests in `SongbirdActorIDTests.swift` are fully superseded by `WireProtocolTests.swift`.

**Files:**
- Modify: `Tests/SongbirdDistributedTests/SongbirdActorIDTests.swift:34-75`

**Step 1: Remove the `@Suite("WireProtocol")` block (lines 34-75)**

Keep the `@Suite("SongbirdActorID")` tests above line 33. Only remove the duplicate `WireProtocolTests` struct.

**Step 2: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -10`
Expected: All pass (the comprehensive tests in `WireProtocolTests.swift` still exist)

**Step 3: Commit**

```
refactor: remove duplicate WireProtocol tests from SongbirdActorIDTests
```

---

## Task 12: Important — Fix AggregateRepositoryTests weak assertion

**Severity:** Important — bare `catch` block swallows error without type-checking.

**Files:**
- Modify: `Tests/SongbirdTests/AggregateRepositoryTests.swift:170-178`

**Step 1: Replace the do/catch with #expect(throws:)**

Replace lines 170-178:

```swift
@Test func executeWithFailedValidation() async throws {
    let (repo, store) = makeRepo()
    // Try to deposit without opening -- should throw .notOpen
    await #expect(throws: BankAccountAggregate.Failure.self) {
        _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)
    }

    // No events should have been appended
    let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
    #expect(events.isEmpty)
}
```

Read the file first to verify the exact error type. The aggregate's `Failure` type should be used.

**Step 2: Run tests**

Run: `swift test --filter AggregateRepositoryTests 2>&1 | tail -5`
Expected: All pass

**Step 3: Commit**

```
test: use typed error assertion in executeWithFailedValidation
```

---

## Task 13: Important — Guard rawExecute with #if DEBUG in Postgres tests

**Severity:** Important — `rawExecute` is only available in `#if DEBUG` builds.

**Files:**
- Modify: `Tests/SongbirdPostgresTests/PostgresChainVerificationTests.swift:51`

**Step 1: Wrap the test that uses rawExecute in `#if DEBUG`**

Read the file. Wrap the `tamperedEventBreaksChain` test in `#if DEBUG ... #endif`.

**Step 2: Run tests**

Run: `swift test --filter PostgresChainVerificationTests 2>&1 | tail -5`
Expected: All pass

**Step 3: Commit**

```
fix: guard rawExecute test with #if DEBUG in Postgres chain verification
```

---

## Task 14: Important — Fix force-unwrap in PostgresEventSubscriptionTests

**Severity:** Important — `group.next()!` can crash the entire test process.

**Files:**
- Modify: `Tests/SongbirdPostgresTests/PostgresEventSubscriptionTests.swift:198`

**Step 1: Replace force-unwrap with guard**

Replace line 198:

```swift
guard let result = try await group.next() else {
    group.cancelAll()
    return []
}
```

**Step 2: Run tests**

Run: `swift test --filter PostgresEventSubscriptionTests 2>&1 | tail -5`
Expected: All pass

**Step 3: Commit**

```
fix: remove force-unwrap on group.next() in subscription test helper
```

---

## Task 15: Important — Replace fatalError in PostgresTestHelper

**Severity:** Important — crashes entire test process instead of failing single test.

**Files:**
- Modify: `Tests/SongbirdPostgresTests/PostgresTestHelper.swift:60-63, 71-76`

**Step 1: Add an error type and throw instead of fatalError**

Add a test helper error:

```swift
enum PostgresTestHelperError: Error {
    case containerNotStarted
}
```

Replace the two `fatalError` calls with `throw PostgresTestHelperError.containerNotStarted`.

Change `makeConfiguration()` and `makeConnectionConfiguration()` to be `throws` functions.

**Step 2: Update callers**

Search for calls to `makeConfiguration()` and `makeConnectionConfiguration()` and add `try` where needed. These are likely already in `throws` contexts.

**Step 3: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -10`
Expected: All pass

**Step 4: Commit**

```
fix: throw instead of fatalError in PostgresTestHelper
```

---

## Task 16: Important — Add MetricsEventStore error recording for reads

**Severity:** Important — read errors skip timer recording; `streamVersion` has zero metrics.

**Files:**
- Modify: `Sources/Songbird/MetricsEventStore.swift:60-122`

**Step 1: Wrap each read method in do/catch like append**

For `readStream`, `readCategories`, `readLastEvent`: wrap in `do/catch`, record timer in both paths, increment error counter on failure.

For `streamVersion` (lines 118-122): add timer and error counter.

Follow the exact pattern from `append` (lines 31-57). Read the file first.

**Step 2: Run tests**

Run: `swift test --filter MetricsEventStoreTests 2>&1 | tail -5`
Expected: All pass

**Step 3: Commit**

```
fix: record metrics for read errors and streamVersion in MetricsEventStore
```

---

## Task 17: Important — Add upcast cycle detection to EventTypeRegistry

**Severity:** Important — unbounded `while true` loop hangs forever on misconfigured cycle.

**Files:**
- Modify: `Sources/Songbird/EventTypeRegistry.swift:95-101`

**Step 1: Add a visited set**

Replace the while loop:

```swift
var currentEventType = recorded.eventType
var visited: Set<String> = [currentEventType]
while true {
    let upcastFn = lock.withLock { upcasts[currentEventType] }
    guard let upcastFn else { break }
    event = upcastFn(event)
    currentEventType = event.eventType
    guard visited.insert(currentEventType).inserted else {
        preconditionFailure("Upcast cycle detected at event type '\(currentEventType)'")
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter EventUpcastTests 2>&1 | tail -5`
Expected: All pass

**Step 3: Commit**

```
fix: add upcast cycle detection to EventTypeRegistry
```

---

## Task 18: Suggestion — Reuse JSONEncoder/JSONDecoder in SQLiteEventStore

**Severity:** Suggestion — allocating fresh instances per call adds GC pressure.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:16-19, 117, 121, 362`

**Step 1: Add stored encoder/decoder properties**

Add alongside the existing `iso8601Formatter`:

```swift
private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()
```

**Step 2: Replace all `JSONEncoder()` and `JSONDecoder()` calls in the actor**

In `append`: replace `try JSONEncoder().encode(event)` with `try jsonEncoder.encode(event)`, etc.
In `recordedEvent(from:)`: replace `try JSONDecoder().decode(...)` with `try jsonDecoder.decode(...)`.

**Step 3: Run tests**

Run: `swift test --filter SongbirdSQLiteTests 2>&1 | tail -5`
Expected: All pass

**Step 4: Commit**

```
perf: reuse JSONEncoder/JSONDecoder in SQLiteEventStore
```

---

## Task 19: Suggestion — Replace empty existential test with meaningful one

**Severity:** Suggestion — `protocolIsUsableAsExistential` tests nothing.

**Files:**
- Modify: `Tests/SongbirdTests/EventStoreTests.swift:32-36`

**Step 1: Replace with a test that actually exercises the existential**

```swift
@Test func protocolIsUsableAsExistential() async throws {
    let store: any EventStore = InMemoryEventStore()
    let version = try await store.streamVersion(StreamName(category: "test"))
    #expect(version == -1)
}
```

Add `import SongbirdTesting` if not already imported.

**Step 2: Run tests**

Run: `swift test --filter EventStoreProtocolTests 2>&1 | tail -5`
Expected: All pass

**Step 3: Commit**

```
test: replace empty existential test with meaningful assertion
```

---

## Task 20: Test Gap — ProcessManagerRunner error path test

**Severity:** Test Gap — no test covers what happens when store.append throws inside processEvent.

**Files:**
- Modify: `Tests/SongbirdTests/ProcessManagerRunnerTests.swift`

**Step 1: Read the file to understand existing test types and patterns**

**Step 2: Add a test using a failing store**

Create a minimal `FailingEventStore` that throws on `append` after a configurable number of successful calls. Or use the existing `InMemoryEventStore` with a mock that can be told to fail.

The test should:
1. Set up a PM runner with a store that fails on append
2. Append events to trigger the PM
3. Run the runner briefly
4. Verify the runner continues processing subsequent events despite the failure (i.e., it doesn't crash)

Follow existing test patterns in the file.

**Step 3: Run tests**

Run: `swift test --filter ProcessManagerRunnerTests 2>&1 | tail -10`
Expected: All pass

**Step 4: Commit**

```
test: add ProcessManagerRunner error path test
```

---

## Task 21: Test Gap — TransportClient external cancellation + unexpected disconnect

**Severity:** Test Gap — no test for external cancellation producing CancellationError (vs timeout), and no test for server crash with pending calls.

**Files:**
- Modify: `Tests/SongbirdDistributedTests/TransportTests.swift`

**Step 1: Add external cancellation test**

```swift
@Test func externalCancellationProducesCancellationError() async throws {
    let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    let server = TransportServer(socketPath: socketPath, handler: SilentHandler())
    try await server.start()
    defer { Task { try await server.stop() } }

    let client = TransportClient(callTimeout: .seconds(30))  // long timeout
    try await client.connect(socketPath: socketPath)
    defer { Task { try await client.disconnect() } }

    let task = Task {
        try await client.call(actorName: "a", targetName: "t", arguments: Data())
    }

    // Give the call time to register, then cancel externally
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected error")
    } catch is CancellationError {
        // Correct: external cancellation should produce CancellationError
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }
}
```

**Step 2: Add unexpected disconnect test**

```swift
@Test func serverCrashResolvePendingCalls() async throws {
    let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    let server = TransportServer(socketPath: socketPath, handler: SilentHandler())
    try await server.start()

    let client = TransportClient(callTimeout: .seconds(30))
    try await client.connect(socketPath: socketPath)

    // Start a call that will never get a response
    let task = Task {
        try await client.call(actorName: "a", targetName: "t", arguments: Data())
    }

    // Give the call time to register
    try await Task.sleep(for: .milliseconds(50))

    // Kill the server (simulating a crash)
    try await server.stop()

    // The pending call should resolve with an error (not hang for 30s)
    await #expect(throws: SongbirdDistributedError.self) {
        _ = try await task.value
    }
}
```

Adapt test code to match actual API patterns. Read the existing tests first.

**Step 3: Run tests**

Run: `swift test --filter TransportTests 2>&1 | tail -15`
Expected: All pass

**Step 4: Commit**

```
test: add external cancellation and unexpected disconnect tests
```

---

## Task 22: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0030-code-review-remediation-round4.md`

**Step 1: Verify clean build**

Run: `swift build 2>&1 | grep -E "warning:|error:|Build complete"`
Expected: "Build complete!" with no new warnings

**Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 3: Write changelog**

Create `changelog/0030-code-review-remediation-round4.md` summarizing:

- Critical fixes: NotificationSignal dictionary mutation, SQLiteEventStore index bypass, cancelPendingCall error type, ActorSystem response encode logging
- Important fixes: ProcessManagerRunner error isolation, verifyChain 0-based consistency, PostgresEventStore timestamp, ClientInboundHandler channelInactive, Postgres verifyChain cursor pagination, retention Duration wiring, duplicate test removal, test assertion quality, rawExecute guard, force-unwrap removal, fatalError replacement, MetricsEventStore read errors, upcast cycle detection
- Suggestions: JSONEncoder reuse, existential test replacement
- Test gaps: PM error path, external cancellation, unexpected disconnect

**Step 4: Commit**

```
Add code review remediation round 4 changelog entry
```
