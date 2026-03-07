# Code Review Remediation (Round 5) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 2 critical issues, 14 important issues, 8 suggestions, and 11 test coverage gaps identified in the fifth comprehensive code review of the Songbird framework.

**Architecture:** Fixes span all modules (Songbird, SongbirdSQLite, SongbirdPostgres, SongbirdDistributed, SongbirdTesting) with focus on Swift 6.2 strict concurrency (`Mutex` over `NSLock`), iterator resource cleanup, cancellation correctness, and comprehensive test coverage.

**Tech Stack:** Swift 6.2, Swift Testing, PostgresNIO, NIOCore, Synchronization (Mutex), CryptoKit

---

### Task 1: PostgresEventSubscription — Remove `[weak self]` and add iterator error cleanup

**Severity:** Critical

**Why:** `[weak self]` on an actor is meaningless in Swift — actors are reference types managed by the runtime, and `weak self` creates a potential silent no-op where `self?.notifyWaiters()` silently does nothing if the reference is nil, leaking continuations. Additionally, when `next()` throws (e.g., from `store.readCategories`), the LISTEN connection is never cleaned up because `notificationSignal.stop()` only runs on the cancellation path (line 276).

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift`
- Test: `Tests/SongbirdPostgresTests/PostgresEventSubscriptionTests.swift`

**Step 1: Fix `[weak self]` and add error cleanup**

In `NotificationSignal.start()` (line 30), remove `[weak self = self]` — just use `self` directly since the actor keeps itself alive while the Task runs:

```swift
// Line 30: Change from:
self.listenTask = Task { [weak self = self] in
    try await conn.listen(on: "songbird_events") { notifications in
        for try await _ in notifications {
            await self?.notifyWaiters()
        }
    }
}
// To:
self.listenTask = Task {
    try await conn.listen(on: "songbird_events") { notifications in
        for try await _ in notifications {
            await self.notifyWaiters()
        }
    }
}
```

In `NotificationSignal.wait()` (line 56), same fix:

```swift
// Line 56: Change from:
Task { [weak self = self] in
    try? await Task.sleep(for: timeout)
    await self?.timeoutWaiter(id: id)
}
// To:
Task {
    try? await Task.sleep(for: timeout)
    await self.timeoutWaiter(id: id)
}
```

In `Iterator.next()`, wrap the main body in a do/catch that ensures cleanup on error. Change the method to use a defer-like pattern. Replace lines 199-278:

```swift
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

    // Current batch exhausted -- save position if we had events
    if !currentBatch.isEmpty {
        let lastPosition = currentBatch[currentBatch.count - 1].globalPosition
        try await positionStore.save(
            subscriberId: subscriberId,
            globalPosition: lastPosition
        )
        globalPosition = lastPosition
    }

    // Ensure LISTEN connection is started
    if !listenStarted {
        try await notificationSignal.start(config: connectionConfig, logger: logger)
        listenStarted = true
    }

    // Poll loop with LISTEN wakeup
    do {
        while !Task.isCancelled {
            try Task.checkCancellation()

            // Poll for events
            let batch = try await store.readCategories(
                categories,
                from: globalPosition + 1,
                maxCount: batchSize
            )

            if !batch.isEmpty {
                currentBatch = batch
                batchIndex = 1
                return batch[0]
            }

            // Caught up -- wait for LISTEN notification or fallback timeout
            let notified = await notificationSignal.wait(timeout: fallbackPollInterval)

            if !notified {
                let fallbackBatch = try await store.readCategories(
                    categories,
                    from: globalPosition + 1,
                    maxCount: batchSize
                )

                if !fallbackBatch.isEmpty {
                    logger.warning(
                        "Fallback poll found events missed by LISTEN -- re-establishing connection",
                        metadata: ["subscriberId": "\(subscriberId)"]
                    )
                    try await notificationSignal.reconnect(
                        config: connectionConfig,
                        logger: logger
                    )
                    currentBatch = fallbackBatch
                    batchIndex = 1
                    return fallbackBatch[0]
                }
            }
        }
    } catch {
        // Clean up LISTEN connection on any error (including CancellationError)
        await notificationSignal.stop()
        throw error
    }

    // Cancelled via Task.isCancelled flag -- clean up LISTEN connection
    await notificationSignal.stop()
    return nil
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -5`
Expected: All Postgres tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresEventSubscription.swift
git commit -m "fix(critical): remove [weak self] on actor, add iterator error cleanup in PostgresEventSubscription"
```

---

### Task 2: Add Task.checkCancellation to initial fold loops

**Severity:** Important

**Why:** `AggregateStateStream`, `AggregateRepository`, and `ProcessStateStream` all have initial fold loops that read potentially thousands of events without checking for cancellation. A cancelled task will wastefully fold the entire history before exiting.

**Files:**
- Modify: `Sources/Songbird/AggregateStateStream.swift:113-130`
- Modify: `Sources/Songbird/AggregateRepository.swift:38-50`
- Modify: `Sources/Songbird/ProcessStateStream.swift:94-107`

**Step 1: Add cancellation checks**

In `AggregateStateStream.Iterator.next()`, add `try Task.checkCancellation()` at the top of the initial fold while loop (after line 113):

```swift
while true {
    try Task.checkCancellation()
    let batch = try await store.readStream(
```

In `AggregateRepository.load()`, add the same check at the top of the fold while loop (after line 38):

```swift
while true {
    try Task.checkCancellation()
    let records = try await store.readStream(stream, from: currentPosition, maxCount: batchSize)
```

In `ProcessStateStream.Iterator.next()`, add the same check in the initial fold (after line 94):

```swift
while true {
    try Task.checkCancellation()
    let batch = try await store.readCategories(
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/Songbird/AggregateStateStream.swift Sources/Songbird/AggregateRepository.swift Sources/Songbird/ProcessStateStream.swift
git commit -m "fix: add Task.checkCancellation to initial fold loops"
```

---

### Task 3: GatewayRunner — rethrow CancellationError

**Severity:** Important

**Why:** `ProcessManagerRunner.run()` already rethrows `CancellationError` (lines 74-75) so callers can distinguish cancellation from other failures. `GatewayRunner.run()` swallows ALL errors in its catch block (line 76-96), meaning a `CancellationError` from `gateway.handle()` silently continues the subscription instead of propagating cancellation.

**Files:**
- Modify: `Sources/Songbird/GatewayRunner.swift:63-98`
- Test: `Tests/SongbirdTests/GatewayRunnerTests.swift`

**Step 1: Add CancellationError rethrow**

In `GatewayRunner.run()`, add a `catch is CancellationError` clause before the general catch (between lines 76 and 77):

```swift
for try await event in subscription {
    let start = ContinuousClock.now
    do {
        try await gateway.handle(event)
        let elapsed = ContinuousClock.now - start
        Metrics.Timer(
            label: "songbird_gateway_delivery_duration_seconds",
            dimensions: [("gateway_id", gateway.gatewayId)]
        ).recordNanoseconds(elapsed.nanoseconds)
        Counter(
            label: "songbird_gateway_delivery_total",
            dimensions: [("gateway_id", gateway.gatewayId), ("status", "success")]
        ).increment()
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        let elapsed = ContinuousClock.now - start
        // ... rest of existing catch block unchanged
```

**Step 2: Run tests**

Run: `swift test --filter GatewayRunner 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/Songbird/GatewayRunner.swift
git commit -m "fix: rethrow CancellationError in GatewayRunner matching ProcessManagerRunner pattern"
```

---

### Task 4: Fix MetricsEventStore test label + add read error tests

**Severity:** Important + Test Gap

**Why:** `streamVersionEmitsNoMetrics` test checks for `songbird_event_store_read_duration_seconds` with `read_type: "streamVersion"`, but MetricsEventStore actually uses `songbird_event_store_stream_version_duration_seconds`. The test passes by accident (timer is nil either way). Also, no tests verify that read methods record error metrics on failure.

**Files:**
- Modify: `Tests/SongbirdTests/MetricsEventStoreTests.swift`

**Step 1: Fix the streamVersion test**

Replace the `streamVersionEmitsNoMetrics` test (lines 223-241) with a test that verifies the correct metric IS emitted:

```swift
@Test func streamVersionEmitsDurationTimer() async throws {
    let store = makeStore()
    let stream = StreamName(category: "order", id: "1")

    _ = try await store.append(
        TestEvent(data: "a"), to: stream,
        metadata: EventMetadata(), expectedVersion: nil
    )
    TestMetricsFactory.shared.reset()

    _ = try await store.streamVersion(stream)

    let timer = TestMetricsFactory.shared.timer(
        "songbird_event_store_stream_version_duration_seconds",
        dimensions: [("stream_category", "order")]
    )
    #expect(timer != nil)
    #expect((timer?.values.count ?? 0) == 1)
}
```

**Step 2: Add read error tests**

Add a `FailingReadStore` and tests after the existing `FailingAppendStore`:

```swift
/// An event store that always throws on read operations.
private actor FailingReadStore: EventStore {
    func append(_ event: some Event, to stream: StreamName, metadata: EventMetadata, expectedVersion: Int64?) async throws -> RecordedEvent {
        RecordedEvent(
            id: UUID(), streamName: stream, position: 0, globalPosition: 0,
            eventType: "Test", data: Data(), metadata: metadata, timestamp: Date()
        )
    }
    func readStream(_ stream: StreamName, from position: Int64, maxCount: Int) async throws -> [RecordedEvent] {
        throw StoreError()
    }
    func readCategories(_ categories: [String], from globalPosition: Int64, maxCount: Int) async throws -> [RecordedEvent] {
        throw StoreError()
    }
    func readLastEvent(in stream: StreamName) async throws -> RecordedEvent? {
        throw StoreError()
    }
    func streamVersion(_ stream: StreamName) async throws -> Int64 {
        throw StoreError()
    }
}

@Test func readStreamErrorRecordsMetrics() async throws {
    let metricsStore = MetricsEventStore(inner: FailingReadStore())
    let stream = StreamName(category: "order", id: "1")

    do {
        _ = try await metricsStore.readStream(stream, from: 0, maxCount: 10)
    } catch {}

    let errorCounter = TestMetricsFactory.shared.counter(
        "songbird_event_store_read_errors_total",
        dimensions: [("stream_category", "order"), ("read_type", "stream")]
    )
    #expect(errorCounter?.totalValue == 1)

    let timer = TestMetricsFactory.shared.timer(
        "songbird_event_store_read_duration_seconds",
        dimensions: [("stream_category", "order"), ("read_type", "stream")]
    )
    #expect(timer != nil)
}

@Test func readCategoriesErrorRecordsMetrics() async throws {
    let metricsStore = MetricsEventStore(inner: FailingReadStore())

    do {
        _ = try await metricsStore.readCategories(["order"], from: 0, maxCount: 10)
    } catch {}

    let errorCounter = TestMetricsFactory.shared.counter(
        "songbird_event_store_read_errors_total",
        dimensions: [("read_type", "categories")]
    )
    #expect(errorCounter?.totalValue == 1)
}

@Test func readLastEventErrorRecordsMetrics() async throws {
    let metricsStore = MetricsEventStore(inner: FailingReadStore())
    let stream = StreamName(category: "order", id: "1")

    do {
        _ = try await metricsStore.readLastEvent(in: stream)
    } catch {}

    let errorCounter = TestMetricsFactory.shared.counter(
        "songbird_event_store_read_errors_total",
        dimensions: [("stream_category", "order"), ("read_type", "lastEvent")]
    )
    #expect(errorCounter?.totalValue == 1)
}

@Test func streamVersionErrorRecordsMetrics() async throws {
    let metricsStore = MetricsEventStore(inner: FailingReadStore())
    let stream = StreamName(category: "order", id: "1")

    do {
        _ = try await metricsStore.streamVersion(stream)
    } catch {}

    let errorCounter = TestMetricsFactory.shared.counter(
        "songbird_event_store_stream_version_errors_total",
        dimensions: [("stream_category", "order")]
    )
    #expect(errorCounter?.totalValue == 1)
}
```

**Step 3: Fix force unwraps in existing tests**

Replace all `timer!.values[0]` and `timer!.values.count` patterns with safe access:

```swift
// Replace patterns like:
#expect(timer!.values.count == 1)
#expect(timer!.values[0] > 0)
// With:
#expect((timer?.values.count ?? 0) == 1)
#expect((timer?.values.first ?? 0) > 0)
```

Apply this to all force unwraps in the file (approximately lines 43-44, 187).

**Step 4: Run tests**

Run: `swift test --filter MetricsEventStoreTests 2>&1 | tail -5`
Expected: All tests pass (including new ones)

**Step 5: Commit**

```bash
git add Tests/SongbirdTests/MetricsEventStoreTests.swift
git commit -m "fix: correct MetricsEventStore test label, add read error tests, remove force unwraps"
```

---

### Task 5: SQLiteEventStore verifyChain — OFFSET to cursor-based pagination

**Severity:** Important

**Why:** `SQLiteEventStore.verifyChain` uses `OFFSET`-based pagination (line 258), which is O(N^2) total work for large tables. PostgresEventStore was fixed in round 4 to use cursor-based `WHERE global_position > lastSeen`. SQLite should match.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:248-300`
- Test: `Tests/SongbirdTests/SQLiteEventStoreTests.swift` (or wherever chain verification tests live)

**Step 1: Replace OFFSET with cursor-based pagination**

Replace lines 248-300:

```swift
public func verifyChain(batchSize: Int = 1000) async throws -> ChainVerificationResult {
    var previousHash = "genesis"
    var verified = 0
    var lastGlobalPosition: Int64 = 0  // AUTOINCREMENT starts at 1, so 0 means "before first"

    while true {
        let rows = try db.prepare("""
            SELECT global_position, event_type, stream_name, data, timestamp, event_hash
            FROM events
            WHERE global_position > ?
            ORDER BY global_position ASC
            LIMIT ?
        """, lastGlobalPosition, batchSize)

        var batchCount = 0
        for row in rows {
            batchCount += 1
            guard let globalPos = row[0] as? Int64,
                  let eventType = row[1] as? String,
                  let streamName = row[2] as? String,
                  let data = row[3] as? String,
                  let timestamp = row[4] as? String
            else {
                throw SQLiteEventStoreError.corruptedRow(column: "chain_verification", globalPosition: nil)
            }
            let storedHash = row[5] as? String
            lastGlobalPosition = globalPos

            let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(data)\0\(timestamp)"
            let computedHash = SHA256.hash(data: Data(hashInput.utf8))
                .map { String(format: "%02x", $0) }
                .joined()

            if let storedHash, storedHash != computedHash {
                return ChainVerificationResult(
                    intact: false,
                    eventsVerified: verified,
                    brokenAtSequence: globalPos - 1
                )
            }

            previousHash = storedHash ?? computedHash
            verified += 1
        }

        if batchCount < batchSize { break }

        // Yield between batches to avoid monopolizing the executor during
        // long chain verifications.
        await Task.yield()
    }

    return ChainVerificationResult(intact: true, eventsVerified: verified)
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdSQLite/SQLiteEventStore.swift
git commit -m "fix: replace OFFSET with cursor-based pagination in SQLiteEventStore.verifyChain"
```

---

### Task 6: SQLiteKeyStore — check expires_at + ON CONFLICT + tests

**Severity:** Important

**Why:** `existingKey(for:layer:)` doesn't filter on `expires_at`, so expired keys are returned as valid. `key(for:layer:)` lacks `ON CONFLICT` so concurrent insertions for the same (reference, layer) will throw a unique constraint error instead of being handled gracefully (PostgresKeyStore already has ON CONFLICT). No tests verify expiry behavior.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteKeyStore.swift:58-93`
- Test: `Tests/SongbirdTests/SQLiteKeyStoreTests.swift` (create if needed, or find existing)

**Step 1: Fix existingKey to check expires_at**

Replace `existingKey(for:layer:)` (lines 82-93):

```swift
public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
    let nowStr = iso8601Formatter.string(from: Date())
    let rows = try db.prepare(
        "SELECT key_data FROM encryption_keys WHERE reference = ? AND layer = ? AND (expires_at IS NULL OR expires_at > ?) LIMIT 1",
        reference, layer.rawValue, nowStr
    )

    for row in rows {
        guard let blob = row[0] as? Blob else { return nil }
        return SymmetricKey(data: Data(blob.bytes))
    }
    return nil
}
```

**Step 2: Add ON CONFLICT to key() INSERT**

Replace the INSERT in `key(for:layer:expiresAfter:)` (lines 71-77):

```swift
try db.run(
    """
    INSERT OR IGNORE INTO encryption_keys (reference, layer, key_data, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?)
    """,
    reference, layer.rawValue, Blob(bytes: [UInt8](keyData)), nowStr, expiresAtStr
)

// Re-read to handle the race: if our INSERT was ignored (concurrent insert won),
// return the existing key.
if let existing = try await existingKey(for: reference, layer: layer) {
    return existing
}

// Should not reach here: we just inserted or another caller did
return newKey
```

**Step 3: Also fix hasKey to check expires_at**

Replace `hasKey(for:layer:)` (lines 102-113):

```swift
public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
    let nowStr = iso8601Formatter.string(from: Date())
    let rows = try db.prepare(
        "SELECT COUNT(*) FROM encryption_keys WHERE reference = ? AND layer = ? AND (expires_at IS NULL OR expires_at > ?)",
        reference, layer.rawValue, nowStr
    )

    for row in rows {
        guard let count = row[0] as? Int64 else { return false }
        return count > 0
    }
    return false
}
```

**Step 4: Find or create SQLiteKeyStore test file and add expiry test**

Look for existing tests in `Tests/SongbirdTests/` for SQLiteKeyStore. If they exist, add to them. Otherwise find the correct location. Add:

```swift
@Test func expiredKeyIsNotReturned() async throws {
    let store = try SQLiteKeyStore(path: ":memory:")
    // Create a key that expires in the past (0 seconds = already expired)
    // We need to manually insert with a past expires_at
    _ = try await store.key(for: "entity-1", layer: .retention, expiresAfter: .seconds(1))

    // Key exists right now
    #expect(try await store.existingKey(for: "entity-1", layer: .retention) != nil)

    // Tamper: set expires_at to a past date
    try store.db.run(
        "UPDATE encryption_keys SET expires_at = ? WHERE reference = ? AND layer = ?",
        "2020-01-01T00:00:00Z", "entity-1", "retention"
    )

    // Expired key should not be returned
    #expect(try await store.existingKey(for: "entity-1", layer: .retention) == nil)
    #expect(try await store.hasKey(for: "entity-1", layer: .retention) == false)
}
```

**Step 5: Run tests**

Run: `swift test 2>&1 | tail -5`
Expected: All tests pass

**Step 6: Commit**

```bash
git add Sources/SongbirdSQLite/SQLiteKeyStore.swift Tests/
git commit -m "fix: SQLiteKeyStore checks expires_at, adds ON CONFLICT for concurrent safety"
```

---

### Task 7: PostgresKeyStore — fix Duration precision loss

**Severity:** Important

**Why:** `Duration.components.seconds` discards the attoseconds component. A duration of 1.5 seconds becomes 1 second in the `make_interval()` call. Use `TimeInterval` conversion for full precision.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresKeyStore.swift:29-35`

**Step 1: Fix Duration to TimeInterval conversion**

Replace lines 29-35:

```swift
if let expiresAfter {
    let (seconds, attoseconds) = expiresAfter.components
    let totalSeconds = Double(seconds) + Double(attoseconds) / 1e18
    try await client.query("""
        INSERT INTO encryption_keys (reference, layer, key_data, created_at, expires_at)
        VALUES (\(reference), \(layerStr), \(keyBytes), NOW(), NOW() + make_interval(secs => \(totalSeconds)))
        ON CONFLICT (reference, layer) DO NOTHING
        """)
} else {
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresKeyStore.swift
git commit -m "fix: preserve sub-second Duration precision in PostgresKeyStore"
```

---

### Task 8: LockedBox — replace NSLock with Mutex

**Severity:** Important

**Why:** Swift 6.2 provides `Mutex<T>` from the `Synchronization` module, which is a value-type-friendly, Sendable-by-construction lock. `LockedBox` uses `NSLock` + `@unchecked Sendable`, which is the old pattern. `Mutex<T>` eliminates the need for `@unchecked Sendable` entirely.

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift:209-225`

**Step 1: Replace LockedBox with Mutex**

Replace the `LockedBox` class (lines 209-225) with:

```swift
import Synchronization

/// A simple thread-safe wrapper for mutable state using Swift 6.2 Mutex.
final class LockedBox<T: Sendable>: Sendable {
    private let mutex: Mutex<T>

    init(_ value: T) {
        self.mutex = Mutex(value)
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        mutex.withLock { body(&$0) }
    }
}
```

Also add `import Synchronization` at the top of the file if not already present.

**Step 2: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdDistributed/SongbirdActorSystem.swift
git commit -m "fix: replace NSLock with Mutex in LockedBox"
```

---

### Task 9: TestMetricsFactory — replace NSLock with Mutex

**Severity:** Important

**Why:** Same reasoning as Task 8. `TestMetricsFactory`, `TestCounter`, `TestTimer`, and `TestRecorder` all use `NSLock` + `@unchecked Sendable`. Replace with `Mutex`.

**Files:**
- Modify: `Sources/SongbirdTesting/TestMetricsFactory.swift`

**Step 1: Replace NSLock with Mutex in all 4 types**

Add `import Synchronization` at top.

Replace `TestMetricsFactory` (keeping same public API):

```swift
public final class TestMetricsFactory: MetricsFactory, Sendable {
    public static let shared = TestMetricsFactory()

    private static let _doBootstrap: Bool = {
        MetricsSystem.bootstrap(TestMetricsFactory.shared)
        return true
    }()

    public static func bootstrap() {
        _ = _doBootstrap
    }

    private let state = Mutex<State>(State())

    private struct State {
        var counters: [String: TestCounter] = [:]
        var timers: [String: TestTimer] = [:]
        var recorders: [String: TestRecorder] = [:]
    }

    init() {}

    public func reset() {
        state.withLock { state in
            for counter in state.counters.values { counter.reset() }
            for timer in state.timers.values { timer.reset() }
            for recorder in state.recorders.values { recorder.reset() }
        }
    }

    // MARK: - MetricsFactory

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        state.withLock { state in
            let key = Self.makeKey(label, dimensions)
            if let existing = state.counters[key] { return existing }
            let handler = TestCounter()
            state.counters[key] = handler
            return handler
        }
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        state.withLock { state in
            let key = Self.makeKey(label, dimensions)
            if let existing = state.recorders[key] { return existing }
            let handler = TestRecorder()
            state.recorders[key] = handler
            return handler
        }
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        state.withLock { state in
            let key = Self.makeKey(label, dimensions)
            if let existing = state.timers[key] { return existing }
            let handler = TestTimer()
            state.timers[key] = handler
            return handler
        }
    }

    public func destroyCounter(_ handler: CounterHandler) {}
    public func destroyRecorder(_ handler: RecorderHandler) {}
    public func destroyTimer(_ handler: TimerHandler) {}

    // MARK: - Query API

    public func counter(_ label: String, dimensions: [(String, String)] = []) -> TestCounter? {
        state.withLock { $0.counters[Self.makeKey(label, dimensions)] }
    }

    public func timer(_ label: String, dimensions: [(String, String)] = []) -> TestTimer? {
        state.withLock { $0.timers[Self.makeKey(label, dimensions)] }
    }

    public func gauge(_ label: String, dimensions: [(String, String)] = []) -> TestRecorder? {
        state.withLock { $0.recorders[Self.makeKey(label, dimensions)] }
    }

    // MARK: - Key Construction

    private static func makeKey(_ label: String, _ dimensions: [(String, String)]) -> String {
        if dimensions.isEmpty { return label }
        let dims = dimensions.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        return "\(label)[\(dims)]"
    }
}
```

Replace `TestCounter`:

```swift
public final class TestCounter: CounterHandler, Sendable {
    private let _value = Mutex<Int64>(0)
    public var totalValue: Int64 { _value.withLock { $0 } }

    public func increment(by amount: Int64) {
        _value.withLock { $0 += amount }
    }

    public func reset() {
        _value.withLock { $0 = 0 }
    }
}
```

Replace `TestTimer`:

```swift
public final class TestTimer: TimerHandler, Sendable {
    private let _values = Mutex<[Int64]>([])
    public var values: [Int64] { _values.withLock { $0 } }
    public var lastValue: Int64? { _values.withLock { $0.last } }

    public func recordNanoseconds(_ duration: Int64) {
        _values.withLock { $0.append(duration) }
    }

    public func reset() {
        _values.withLock { $0.removeAll() }
    }
}
```

Replace `TestRecorder`:

```swift
public final class TestRecorder: RecorderHandler, Sendable {
    private let state = Mutex<RecorderState>(RecorderState())

    private struct RecorderState {
        var lastValue: Double?
        var values: [Double] = []
    }

    public var lastValue: Double? { state.withLock { $0.lastValue } }
    public var values: [Double] { state.withLock { $0.values } }

    public func record(_ value: Int64) {
        state.withLock {
            let d = Double(value)
            $0.lastValue = d
            $0.values.append(d)
        }
    }

    public func record(_ value: Double) {
        state.withLock {
            $0.lastValue = value
            $0.values.append(value)
        }
    }

    public func reset() {
        state.withLock {
            $0.lastValue = nil
            $0.values.removeAll()
        }
    }
}
```

**Step 2: Run tests**

Run: `swift test 2>&1 | tail -5`
Expected: All tests pass (Mutex provides same semantics as NSLock)

**Step 3: Commit**

```bash
git add Sources/SongbirdTesting/TestMetricsFactory.swift
git commit -m "fix: replace NSLock with Mutex in TestMetricsFactory and handlers"
```

---

### Task 10: PostgresEventStore — reuse JSONEncoder/JSONDecoder

**Severity:** Important

**Why:** `PostgresEventStore` creates fresh `JSONEncoder()` and `JSONDecoder()` instances on every call (lines 35, 39, 124, 355). `SQLiteEventStore` was already fixed in round 4 to store them as actor properties. PostgresEventStore is a struct (not actor), so store them as `let` properties.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift`

**Step 1: Add stored encoder/decoder properties**

Add after line 14 (after `private let logger`):

```swift
private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()
```

Then replace all `JSONEncoder()` with `jsonEncoder` and `JSONDecoder()` with `jsonDecoder` throughout the file. Specifically:
- Line 35: `let eventData = try jsonEncoder.encode(event)`
- Line 39: `let metadataData = try jsonEncoder.encode(metadata)`
- Line 124: `let iso8601Formatter = ISO8601DateFormatter()` — also store this as a property
- Line 355: `let metadata = try jsonDecoder.decode(EventMetadata.self, from: Data(metadataStr.utf8))`

Also add a stored `ISO8601DateFormatter`:

```swift
private let iso8601Formatter = ISO8601DateFormatter()
```

And replace the local `iso8601Formatter` at line 124 with `self.iso8601Formatter`.

**Step 2: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresEventStore.swift
git commit -m "perf: reuse JSONEncoder/JSONDecoder/ISO8601DateFormatter in PostgresEventStore"
```

---

### Task 11: ContainerState — fix actor re-entrancy in ensureStarted()

**Severity:** Important

**Why:** `ContainerState.ensureStarted()` checks `guard !started` then does async work (waiting for container startup) before setting `started = true`. If two tests call `ensureStarted()` concurrently, the actor's re-entrancy at suspension points means both can pass the guard and start duplicate containers.

**Files:**
- Modify: `Tests/SongbirdPostgresTests/PostgresTestHelper.swift:18-49`

**Step 1: Set started flag before the await**

Replace `ensureStarted()` (lines 18-49):

```swift
func ensureStarted() async throws {
    guard !started else { return }
    started = true  // Set immediately to prevent re-entrant calls

    let (stream, continuation) = AsyncStream<(String, Int)>.makeStream()

    // Launch container in a detached task — lives for the process duration.
    Task.detached {
        let postgres = PostgresContainer()
            .withDatabase("songbird_test")
            .withUsername("songbird")
            .withPassword("songbird")
        try await withPostgresContainer(postgres) { container in
            let mappedPort = try await container.port()
            let mappedHost = container.host()
            continuation.yield((mappedHost, mappedPort))
            continuation.finish()
            // Keep the container alive until the process exits
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3600))
            }
        }
    }

    // Wait for connection info from the container
    for await (h, p) in stream {
        self.host = h
        self.port = p
        break
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/SongbirdPostgresTests/PostgresTestHelper.swift
git commit -m "fix: prevent duplicate container starts in ContainerState via early flag set"
```

---

### Task 12: MessageFrameEncoder — enforce outbound max size

**Severity:** Important

**Why:** `MessageFrameDecoder` enforces `maxWireMessageSize` (16 MB) on inbound messages but `MessageFrameEncoder` has no corresponding check on outbound. A programming error that produces an oversized response would be silently sent and rejected by the receiver, making debugging difficult.

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:244-255`

**Step 1: Add size check to MessageFrameEncoder.write**

Replace the `write` method (lines 248-254):

```swift
func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let payload = unwrapOutboundIn(data)
    guard payload.readableBytes <= maxWireMessageSize else {
        let error = SongbirdDistributedError.remoteCallFailed(
            "Outbound message exceeds max size (\(payload.readableBytes) > \(maxWireMessageSize))"
        )
        promise?.fail(error)
        return
    }
    var frame = context.channel.allocator.buffer(capacity: 4 + payload.readableBytes)
    frame.writeInteger(UInt32(payload.readableBytes))
    frame.writeImmutableBuffer(payload)
    context.write(NIOAny(frame), promise: promise)
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdDistributed/Transport.swift
git commit -m "fix: enforce max message size on outbound in MessageFrameEncoder"
```

---

### Task 13: Make NOTIFY channel configurable

**Severity:** Suggestion

**Why:** The PostgreSQL LISTEN/NOTIFY channel name `"songbird_events"` is hard-coded in both `PostgresEventStore.append()` (line 91) and `NotificationSignal.start()` (line 31). If multiple Songbird instances share a database with different event tables, they'd interfere. Making this configurable prevents that.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift`
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift`

**Step 1: Add notifyChannel parameter to PostgresEventStore**

Add a stored property and init parameter:

```swift
public struct PostgresEventStore: EventStore, Sendable {
    private let client: PostgresClient
    private let registry: EventTypeRegistry
    private let logger = Logger(label: "songbird.postgres")
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let iso8601Formatter = ISO8601DateFormatter()

    /// The PostgreSQL NOTIFY channel name used for event notifications.
    public let notifyChannel: String

    public init(client: PostgresClient, registry: EventTypeRegistry, notifyChannel: String = "songbird_events") {
        self.client = client
        self.registry = registry
        self.notifyChannel = notifyChannel
    }
```

Replace the hard-coded channel in `append()` (line 91):

```swift
try await connection.query(
    "SELECT pg_notify(\(notifyChannel), \(String(globalPosition)))",
    logger: logger
)
```

**Step 2: Add notifyChannel parameter to PostgresEventSubscription and NotificationSignal**

In `NotificationSignal.start()`, accept the channel name:

```swift
func start(config: PostgresConnection.Configuration, logger: Logger, channel: String) async throws {
    // ...
    self.listenTask = Task {
        try await conn.listen(on: channel) { notifications in
```

In `PostgresEventSubscription`, add a stored property:

```swift
public let notifyChannel: String

public init(
    store: PostgresEventStore,
    connectionConfig: PostgresConnection.Configuration,
    subscriberId: String,
    categories: [String],
    positionStore: any PositionStore,
    batchSize: Int = 100,
    fallbackPollInterval: Duration = .seconds(5),
    notifyChannel: String = "songbird_events"
) {
    // ...
    self.notifyChannel = notifyChannel
}
```

Thread it through to `Iterator` and to `notificationSignal.start(config:, logger:, channel:)`.

**Step 3: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -5`
Expected: All tests pass (default value preserves existing behavior)

**Step 4: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresEventStore.swift Sources/SongbirdPostgres/PostgresEventSubscription.swift
git commit -m "feat: make NOTIFY channel name configurable in PostgresEventStore/Subscription"
```

---

### Task 14: InvocationEncoder/Decoder — reuse JSON coders

**Severity:** Suggestion

**Why:** `SongbirdInvocationEncoder.recordArgument` creates a fresh `JSONEncoder()` per argument (line 22). `SongbirdInvocationDecoder.init` and `decodeNextArgument` each create fresh `JSONDecoder()` instances (lines 16, 35). These should be stored properties.

**Files:**
- Modify: `Sources/SongbirdDistributed/InvocationEncoder.swift`
- Modify: `Sources/SongbirdDistributed/InvocationDecoder.swift`

**Step 1: Fix InvocationEncoder**

Add a stored encoder and use it:

```swift
public struct SongbirdInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable

    var targetName: String = ""
    var arguments: [Data] = []
    private let encoder = JSONEncoder()

    public mutating func recordArgument<Value: Codable>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        let data = try encoder.encode(argument.value)
        arguments.append(data)
    }

    func encodeArguments() throws -> Data {
        let base64Args = arguments.map { $0.base64EncodedString() }
        return try encoder.encode(base64Args)
    }
    // ... rest unchanged
}
```

**Step 2: Fix InvocationDecoder**

Add a stored decoder:

```swift
public final class SongbirdInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable

    private let argumentChunks: [Data]
    private var index: Int = 0
    private let decoder = JSONDecoder()

    public init(data: Data) throws {
        let initDecoder = JSONDecoder()
        let base64Args = try initDecoder.decode([String].self, from: data)
        self.argumentChunks = try base64Args.map { base64 in
            guard let data = Data(base64Encoded: base64) else {
                throw SongbirdDistributedError.invalidArgumentEncoding
            }
            return data
        }
    }

    public func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard index < argumentChunks.count else {
            throw SongbirdDistributedError.argumentCountMismatch
        }
        let data = argumentChunks[index]
        index += 1
        return try decoder.decode(Argument.self, from: data)
    }
    // ... rest unchanged
}
```

**Step 3: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add Sources/SongbirdDistributed/InvocationEncoder.swift Sources/SongbirdDistributed/InvocationDecoder.swift
git commit -m "perf: reuse JSONEncoder/JSONDecoder in InvocationEncoder/Decoder"
```

---

### Task 15: SQLiteSnapshotStore — throw on corrupted data instead of silent nil

**Severity:** Suggestion

**Why:** `SQLiteSnapshotStore.loadData()` returns `nil` when `row[0] as? Blob` or `row[1] as? Int64` fails (lines 83-84). This silently treats corrupted data as "no snapshot", causing a full event replay instead of surfacing the corruption. Should throw a descriptive error.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift:74-89`

**Step 1: Replace silent nil returns with throws**

Add an error type at the top of the file (or use an existing one):

```swift
public enum SQLiteSnapshotStoreError: Error {
    case corruptedRow(column: String, streamName: String)
}
```

Replace `loadData()`:

```swift
public func loadData(
    for stream: StreamName
) async throws -> (data: Data, version: Int64)? {
    let rows = try db.prepare(
        "SELECT state, version FROM snapshots WHERE stream_name = ? LIMIT 1",
        stream.description
    )

    for row in rows {
        guard let blob = row[0] as? Blob else {
            throw SQLiteSnapshotStoreError.corruptedRow(column: "state", streamName: stream.description)
        }
        guard let version = row[1] as? Int64 else {
            throw SQLiteSnapshotStoreError.corruptedRow(column: "version", streamName: stream.description)
        }
        let data = Data(blob.bytes)
        return (data, version)
    }
    return nil
}
```

**Step 2: Run tests**

Run: `swift test 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdSQLite/SQLiteSnapshotStore.swift
git commit -m "fix: throw on corrupted snapshot data instead of silent nil"
```

---

### Task 16: PostgresKeyStore — replace unreachable fallback with preconditionFailure

**Severity:** Suggestion

**Why:** Line 51 (`return newKey`) in `PostgresKeyStore.key()` should never be reached — the ON CONFLICT INSERT either succeeds or is a no-op, and the subsequent re-read should always find the key. The silent fallback masks bugs. Replace with a preconditionFailure.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresKeyStore.swift:44-52`

**Step 1: Replace fallback return**

Replace lines 44-52:

```swift
// Re-read to handle the race: if our INSERT was a no-op,
// this returns the key the other caller inserted.
if let existing = try await existingKey(for: reference, layer: layer) {
    return existing
}

// INSERT succeeded or was a no-op, but re-read found nothing.
// This indicates a bug (e.g., concurrent DELETE between INSERT and SELECT).
preconditionFailure("Key not found after INSERT for reference '\(reference)', layer '\(layer.rawValue)'")
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdPostgresTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresKeyStore.swift
git commit -m "fix: replace unreachable fallback with preconditionFailure in PostgresKeyStore"
```

---

### Task 17: Add verifyChain batchSize boundary tests

**Severity:** Test Gap

**Why:** No tests verify that chain verification works correctly at batch boundaries (e.g., when the chain spans multiple batches). A pagination bug could silently skip events.

**Files:**
- Test: `Tests/SongbirdTests/SQLiteEventStoreTests.swift` (or chain verification test location)

**Step 1: Find existing chain verification tests and add boundary tests**

Search for existing chain verification tests and add alongside them:

```swift
@Test func verifyChainWithBatchSizeOne() async throws {
    let registry = EventTypeRegistry()
    registry.register(BankAccountEvent.self, eventTypes: ["Credited", "Debited"])
    let store = try SQLiteEventStore(path: ":memory:", registry: registry)

    // Append 3 events
    _ = try await store.append(BankAccountEvent.credited(amount: 100),
        to: StreamName(category: "account", id: "1"),
        metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(BankAccountEvent.credited(amount: 200),
        to: StreamName(category: "account", id: "1"),
        metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(BankAccountEvent.credited(amount: 300),
        to: StreamName(category: "account", id: "1"),
        metadata: EventMetadata(), expectedVersion: nil)

    // Verify with batchSize=1 — forces 3 separate batches
    let result = try await store.verifyChain(batchSize: 1)
    #expect(result.intact == true)
    #expect(result.eventsVerified == 3)
}

@Test func verifyChainWithBatchSizeTwo() async throws {
    let registry = EventTypeRegistry()
    registry.register(BankAccountEvent.self, eventTypes: ["Credited", "Debited"])
    let store = try SQLiteEventStore(path: ":memory:", registry: registry)

    // Append 3 events — will require 2 batches with batchSize=2
    _ = try await store.append(BankAccountEvent.credited(amount: 100),
        to: StreamName(category: "account", id: "1"),
        metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(BankAccountEvent.credited(amount: 200),
        to: StreamName(category: "account", id: "1"),
        metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(BankAccountEvent.credited(amount: 300),
        to: StreamName(category: "account", id: "1"),
        metadata: EventMetadata(), expectedVersion: nil)

    let result = try await store.verifyChain(batchSize: 2)
    #expect(result.intact == true)
    #expect(result.eventsVerified == 3)
}
```

**Step 2: Run tests**

Run: `swift test --filter verifyChain 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/
git commit -m "test: add verifyChain batch boundary tests"
```

---

### Task 18: Add ProjectionPipeline.stop() resumes waiters test

**Severity:** Test Gap

**Why:** `ProjectionPipeline.stop()` finishes the stream, which causes `run()` to call `resumeAllWaiters()`. But no test verifies that waiters are actually resumed when stop() is called.

**Files:**
- Test: `Tests/SongbirdTests/ProjectionPipelineTests.swift` (or wherever pipeline tests live)

**Step 1: Find pipeline tests and add stop-resumes-waiters test**

```swift
@Test func stopResumesWaitingCallers() async throws {
    let pipeline = ProjectionPipeline()

    // Start the pipeline
    let runTask = Task { await pipeline.run() }

    // Enqueue an event so the pipeline has a non-negative position
    let event = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "test", id: "1"),
        position: 0, globalPosition: 0,
        eventType: "TestEvent", data: Data(),
        metadata: EventMetadata(), timestamp: Date()
    )
    await pipeline.enqueue(event)

    // Wait briefly for the event to be processed
    try await Task.sleep(for: .milliseconds(50))

    // Start a waiter for a position that hasn't been reached
    let waiterTask = Task {
        try await pipeline.waitForProjection(upTo: 999, timeout: .seconds(10))
    }

    // Give the waiter time to register
    try await Task.sleep(for: .milliseconds(50))

    // Stop the pipeline — should resume all waiters
    await pipeline.stop()

    // Waiter should complete without timeout
    try await waiterTask.value

    runTask.cancel()
}
```

**Step 2: Run tests**

Run: `swift test --filter ProjectionPipeline 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/
git commit -m "test: verify ProjectionPipeline.stop() resumes waiting callers"
```

---

### Task 19: Add EventSubscription cancellation cleanup test

**Severity:** Test Gap

**Why:** No test verifies that `EventSubscription` cleanly terminates when the enclosing Task is cancelled. This is important for ensuring no resource leaks.

**Files:**
- Test: `Tests/SongbirdTests/EventSubscriptionTests.swift` (or wherever subscription tests live)

**Step 1: Find subscription tests and add cancellation test**

```swift
@Test func cancellationStopsSubscription() async throws {
    let store = InMemoryEventStore()
    let positionStore = InMemoryPositionStore()

    let subscription = EventSubscription(
        subscriberId: "test-cancel",
        categories: [],
        store: store,
        positionStore: positionStore,
        tickInterval: .milliseconds(50)
    )

    var eventCount = 0
    let task = Task {
        for try await _ in subscription {
            eventCount += 1
        }
    }

    // Append an event so there's something to process
    _ = try await store.append(
        TestAccountEvent.credited(amount: 100),
        to: StreamName(category: "test", id: "1"),
        metadata: EventMetadata(), expectedVersion: nil
    )

    // Let the subscription process
    try await Task.sleep(for: .milliseconds(200))

    // Cancel and verify it stops
    task.cancel()
    try? await task.value

    // Should have processed at least 1 event and then stopped
    #expect(eventCount >= 1)
}
```

Note: The test event type will need to match whatever event type is already used in the test file.

**Step 2: Run tests**

Run: `swift test --filter EventSubscription 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/
git commit -m "test: verify EventSubscription stops cleanly on cancellation"
```

---

### Task 20: Add InvocationDecoder invalid base64 test

**Severity:** Test Gap

**Why:** `SongbirdInvocationDecoder.init` throws when base64 data is invalid, but no test covers this path.

**Files:**
- Test: `Tests/SongbirdDistributedTests/` (find the appropriate test file)

**Step 1: Add invalid base64 test**

```swift
@Test func invalidBase64ThrowsError() throws {
    // Valid JSON array with invalid base64 strings
    let invalidData = try JSONEncoder().encode(["not-valid-base64!!!"])
    #expect(throws: SongbirdDistributedError.self) {
        _ = try SongbirdInvocationDecoder(data: invalidData)
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/
git commit -m "test: add InvocationDecoder invalid base64 test"
```

---

### Task 21: Add PostgresKeyStore expiry test

**Severity:** Test Gap

**Why:** No Postgres test verifies that `expiresAfter` is correctly stored and that the key is returned before expiry. The SQLite test (Task 6) covers expiry, but Postgres should too.

**Files:**
- Test: `Tests/SongbirdPostgresTests/PostgresKeyStoreTests.swift`

**Step 1: Add expiry test**

```swift
@Test func keyWithExpiresAfterStoresExpiration() async throws {
    try await PostgresTestHelper.withTestClient { client in
        try await PostgresTestHelper.cleanTables(client: client)
        let store = PostgresKeyStore(client: client)

        // Create a key with a long expiry
        let key = try await store.key(for: "entity-expiry", layer: .retention, expiresAfter: .seconds(3600))

        // Key should be retrievable
        let found = try await store.existingKey(for: "entity-expiry", layer: .retention)
        #expect(found == key)

        // Verify expires_at was stored
        let rows = try await client.query(
            "SELECT expires_at FROM encryption_keys WHERE reference = 'entity-expiry' AND layer = 'retention'"
        )
        for try await (expiresAt,) in rows.decode((Date?,).self) {
            #expect(expiresAt != nil)
        }
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter PostgresKeyStore 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/
git commit -m "test: add PostgresKeyStore expiry test"
```

---

### Task 22: Add PostgresEventStore concurrent append version conflict test

**Severity:** Test Gap

**Why:** No Postgres test verifies that concurrent appends to the same stream with the same expected version produce a `VersionConflictError`. The SQLite tests cover this, but Postgres's unique constraint (`23505`) handling path is different.

**Files:**
- Test: `Tests/SongbirdPostgresTests/PostgresEventStoreTests.swift`

**Step 1: Add concurrent version conflict test**

```swift
@Test func concurrentAppendsProduceVersionConflict() async throws {
    try await PostgresTestHelper.withTestClient { client in
        try await PostgresTestHelper.cleanTables(client: client)
        let registry = EventTypeRegistry()
        registry.register(PGAccountEvent.self, eventTypes: ["Credited", "Debited"])
        let store = PostgresEventStore(client: client, registry: registry)
        let stream = StreamName(category: "account", id: "conflict-test")

        // Seed with one event
        _ = try await store.append(
            PGAccountEvent.credited(amount: 100),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        // Attempt two appends with the same expectedVersion — one should fail
        do {
            _ = try await store.append(
                PGAccountEvent.credited(amount: 200),
                to: stream, metadata: EventMetadata(), expectedVersion: 99
            )
            Issue.record("Expected VersionConflictError")
        } catch is VersionConflictError {
            // Expected
        }
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter PostgresEventStoreTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/
git commit -m "test: add PostgresEventStore concurrent version conflict test"
```

---

### Task 23: Remove unused EventTypeRegistry from InMemoryEventStore

**Severity:** Suggestion

**Why:** `InMemoryEventStore` stores a `registry: EventTypeRegistry` property (line 8) that is never used — the store doesn't decode events. However, removing the constructor parameter would be a breaking change. Instead, make it optional with a default value so existing callers still work but new callers don't need to pass it.

**Files:**
- Modify: `Sources/SongbirdTesting/InMemoryEventStore.swift`

**Step 1: Deprecate the registry parameter**

The registry is already optional with a default: `EventTypeRegistry()`. The simplest fix is to just stop storing it since it's never referenced:

Remove `private let registry: EventTypeRegistry` from line 8. The `init` already has `registry: EventTypeRegistry = EventTypeRegistry()` — just stop storing the parameter:

```swift
public actor InMemoryEventStore: EventStore {
    private var events: [RecordedEvent] = []
    private var streamPositions: [StreamName: Int64] = [:]
    private var nextGlobalPosition: Int64 = 0

    public init(registry: EventTypeRegistry = EventTypeRegistry()) {
        // registry parameter kept for API compatibility but not stored —
        // event stores don't need it; decoding happens at the consumer level
    }
```

**Step 2: Run tests**

Run: `swift test 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Sources/SongbirdTesting/InMemoryEventStore.swift
git commit -m "cleanup: stop storing unused EventTypeRegistry in InMemoryEventStore"
```

---

### Task 24: Clean build + full test suite + changelog

**Severity:** Final verification

**Files:**
- Create: `changelog/0031-code-review-remediation-round5.md`

**Step 1: Run full build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with zero errors and zero warnings

**Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Write changelog**

Create `changelog/0031-code-review-remediation-round5.md` with summary of all fixes.

**Step 4: Commit**

```bash
git add changelog/0031-code-review-remediation-round5.md
git commit -m "Add code review remediation round 5 changelog"
```
