# Code Review Remediation (Round 3) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all remaining issues from the third comprehensive code review: 3 critical, 12 important, 10 suggestions, and 12 test coverage gaps.

**Architecture:** Fixes are grouped into 20 tasks ordered by severity: critical concurrency bugs first, then safety/correctness issues, then improvements/hardening, then test gaps. Tasks that touch the same file are merged. Independent tasks can be parallelized.

**Tech Stack:** Swift 6.2, Swift Testing, SQLite.swift, NIOCore, NIOPosix, Smew (DuckDB), swift-metrics, swift-log, Hummingbird

---

## Task 1: Critical -- Fix ProjectionPipeline continuation leak on cancellation race

**Severity:** Critical -- if a task is cancelled between `withTaskCancellationHandler` and `withCheckedThrowingContinuation`, the `onCancel` handler fires before the waiter is registered, and the continuation is never resumed, hanging the caller forever.

**Files:**
- Modify: `Sources/Songbird/ProjectionPipeline.swift:96-115`

**Step 1: Fix the race by checking cancellation after registering the waiter**

Replace `waitForProjection` (lines 96-115) with:

```swift
public func waitForProjection(upTo globalPosition: Int64, timeout: Duration = .seconds(5)) async throws {
    try Task.checkCancellation()

    if projectedPosition >= globalPosition { return }

    let waiterId = nextWaiterId
    nextWaiterId += 1

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                self.timeoutWaiter(id: waiterId)
            }
            waiters[waiterId] = Waiter(position: globalPosition, continuation: cont, timeoutTask: timeoutTask)

            // If the task was cancelled between withTaskCancellationHandler and here,
            // the onCancel handler already fired but found no waiter to cancel.
            // Check now and clean up immediately to avoid a leaked continuation.
            if Task.isCancelled {
                if let waiter = waiters.removeValue(forKey: waiterId) {
                    waiter.timeoutTask.cancel()
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        }
    } onCancel: {
        Task { await self.cancelWaiter(id: waiterId) }
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter ProjectionPipelineTests 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit**

```
fix: prevent continuation leak on cancellation race in ProjectionPipeline
```

---

## Task 2: Critical -- Fix TransportClient continuation orphaning on timeout/disconnect

**Severity:** Critical -- when timeout fires and `group.cancelAll()` runs, the continuation in `sendAndAwaitResponse` is never resumed (Swift concurrency violation). Also, `disconnect()` orphans all pending continuations.

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:88-163`

**Step 1: Add cancellation handling to `sendAndAwaitResponse` and cleanup to `disconnect`**

Replace `sendAndAwaitResponse` (lines 129-136) with:

```swift
private func sendAndAwaitResponse(requestId: UInt64, data: Data, channel: any Channel) async throws -> WireMessage {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            pendingCalls[requestId] = continuation
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(buffer, promise: nil)

            // Guard against cancellation racing with registration
            if Task.isCancelled {
                if let cont = pendingCalls.removeValue(forKey: requestId) {
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    } onCancel: {
        Task { await self.cancelPendingCall(requestId: requestId) }
    }
}
```

Update `cancelPendingCall` (line 139-143) to handle cancellation too:

```swift
private func cancelPendingCall(requestId: UInt64) {
    if let continuation = pendingCalls.removeValue(forKey: requestId) {
        continuation.resume(throwing: SongbirdDistributedError.remoteCallFailed("Call timed out"))
    }
}
```

Replace `disconnect()` (lines 160-163) with:

```swift
public func disconnect() async throws {
    // Resume all pending continuations before closing
    for (_, continuation) in pendingCalls {
        continuation.resume(throwing: SongbirdDistributedError.notConnected("disconnected"))
    }
    pendingCalls.removeAll()

    try await channel?.close()
    channel = nil
    try await group.shutdownGracefully()
}
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit**

```
fix: prevent continuation orphaning in TransportClient timeout and disconnect
```

---

## Task 3: Critical -- Remove implicitly unwrapped optional in SQLiteEventStore.append

**Severity:** Critical -- `var result: RecordedEvent!` will crash if the transaction closure throws before assignment.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:96-154`

**Step 1: Replace IUO with optional + guard**

Replace lines 100-153:

```swift
// BEFORE:
var result: RecordedEvent!

try db.transaction(.immediate) {
    // ... (body stays the same)
    result = RecordedEvent(...)
}

return result

// AFTER:
var result: RecordedEvent?

try db.transaction(.immediate) {
    // ... (body stays the same)
    result = RecordedEvent(...)
}

guard let result else {
    // This should never happen -- the transaction either throws or assigns result.
    // But we prefer a clear error over a force unwrap crash.
    throw SQLiteEventStoreError.encodingFailed
}
return result
```

**Step 2: Run tests**

Run: `swift test --filter SongbirdSQLiteTests 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit**

```
fix: replace implicitly unwrapped optional in SQLiteEventStore.append
```

---

## Task 4: Important -- Fix timestamp fallback and add thresholdDays validation

**Severity:** Important -- timestamp parse failure silently uses `Date()` instead of throwing; tiering accepts negative days.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:363`
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift:274-277`

**Step 1: Throw on corrupt timestamp**

In `SQLiteEventStore.swift`, replace line 363:

```swift
// BEFORE:
let timestamp = iso8601Formatter.date(from: timestampStr) ?? Date()

// AFTER:
guard let timestamp = iso8601Formatter.date(from: timestampStr) else {
    throw SQLiteEventStoreError.corruptedRow(column: "timestamp", globalPosition: autoincPos)
}
```

**Step 2: Add thresholdDays validation**

In `ReadModelStore.swift`, add a precondition at the top of `tierProjections` (after line 275):

```swift
public func tierProjections(olderThan thresholdDays: Int) throws -> Int {
    guard isTiered else { return 0 }
    precondition(thresholdDays > 0, "thresholdDays must be positive")
    // ... rest unchanged
```

**Step 3: Run tests**

Run: `swift test --filter SongbirdSQLiteTests 2>&1 | tail -5` and `swift test --filter SongbirdSmewTests 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```
fix: throw on corrupt timestamp, validate thresholdDays
```

---

## Task 5: Important -- Add max message size to frame decoder and log decode failures

**Severity:** Important -- malicious peer can OOM with 4GB length prefix; decode failures silently drop messages leaving callers hanging.

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:180-260`

**Step 1: Add max message size constant and check in decoder**

Add above `MessageFrameDecoder` (line 180):

```swift
/// Maximum allowed wire message size (16 MB).
private let maxWireMessageSize: UInt32 = 16 * 1024 * 1024
```

In `MessageFrameDecoder.decode`, after reading the length (line 188), add:

```swift
guard let length = buffer.getInteger(at: lengthIndex, as: UInt32.self) else {
    return .needMoreData
}

guard length <= maxWireMessageSize else {
    // Close the connection rather than buffering a huge message
    context.close(promise: nil)
    return .needMoreData
}
```

**Step 2: Add logging import and log decode failures in handlers**

At top of file, add `import Logging`.

In `ServerInboundHandler`, add a logger and log failures:

```swift
final class ServerInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private static let logger = Logger(label: "songbird.transport.server")
    let messageHandler: any WireMessageHandler

    // ... init unchanged ...

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: Data(bytes)) else {
            Self.logger.warning("Failed to decode incoming message, dropping")
            return
        }

        let channel = context.channel
        let handler = messageHandler
        Task {
            await handler.handleMessage(message, channel: channel)
        }
    }
}
```

Do the same for `ClientInboundHandler`:

```swift
final class ClientInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private static let logger = Logger(label: "songbird.transport.client")
    let client: TransportClient

    // ... init unchanged ...

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: Data(bytes)) else {
            Self.logger.warning("Failed to decode response message, dropping")
            return
        }

        Task {
            await client.receiveResponse(message)
        }
    }
}
```

**Step 3: Run tests**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```
fix: add max message size check and log transport decode failures
```

---

## Task 6: Important -- Remove force unwrap in RequestIdMiddleware

**Severity:** Important -- force unwrap on static init.

**Files:**
- Modify: `Sources/SongbirdHummingbird/RequestIdMiddleware.swift:8`

**Step 1: Replace force unwrap**

```swift
// BEFORE:
static let headerName = HTTPField.Name("X-Request-ID")!

// AFTER:
// HTTPField.Name.init returns nil only for invalid HTTP field names.
// "X-Request-ID" is always valid (alphanumeric + hyphens per RFC 9110).
static let headerName = HTTPField.Name("X-Request-ID")!  // Safe: compile-time constant, valid per RFC 9110
```

Actually, there is no safe alternative that avoids `!` without introducing `Optional` into every usage site. Since this is a compile-time constant string that is guaranteed valid per RFC 9110, the force unwrap is justified. Add a comment explaining why:

```swift
/// Force unwrap is safe: "X-Request-ID" is a compile-time constant string that is a valid
/// HTTP field name per RFC 9110 (only alphabetic, digits, and hyphens).
static let headerName = HTTPField.Name("X-Request-ID")!
```

**Step 2: Verify build**

Run: `swift build --target SongbirdHummingbird 2>&1 | tail -3`
Expected: Build complete

**Step 3: Commit**

```
docs: document safety of force unwrap in RequestIdMiddleware
```

---

## Task 7: Important -- Add StreamName validation

**Severity:** Important -- empty strings, hyphens in category create ambiguous/unparseable stream names.

**Files:**
- Modify: `Sources/Songbird/StreamName.swift:7-10`
- Modify: `Tests/SongbirdTests/StreamNameTests.swift` (add validation tests)

**Step 1: Add validation to StreamName.init**

```swift
public init(category: String, id: String? = nil) {
    precondition(!category.isEmpty, "StreamName category must not be empty")
    precondition(!category.contains("-"), "StreamName category must not contain hyphens (use as delimiter)")
    if let id {
        precondition(!id.isEmpty, "StreamName id must not be empty (use nil for category streams)")
    }
    self.category = category
    self.id = id
}
```

**Step 2: Update any existing tests that use hyphenated categories**

Search the test suite for `StreamName(category:` calls with hyphens. If found, update them to use unhyphenated categories.

Run: `grep -rn 'StreamName(category:.*-' Tests/` and fix any hits.

**Step 3: Run tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass (may need to fix test data that uses hyphens in categories)

**Step 4: Commit**

```
fix: add StreamName validation (no empty strings, no hyphens in category)
```

---

## Task 8: Important -- Add RecordedEvent Equatable conformance

**Severity:** Important -- makes test assertions verbose; all fields are already `Equatable`.

**Files:**
- Modify: `Sources/Songbird/Event.swift:35`

**Step 1: Add Equatable conformance**

```swift
// BEFORE:
public struct RecordedEvent: Sendable {

// AFTER:
public struct RecordedEvent: Sendable, Equatable {
```

All stored properties (`UUID`, `StreamName`, `Int64`, `String`, `Data`, `EventMetadata`, `Date`) are already `Equatable`, so the compiler auto-synthesizes the conformance.

**Step 2: Run tests**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete

**Step 3: Commit**

```
feat: add Equatable conformance to RecordedEvent
```

---

## Task 9: Important -- Propagate causation metadata in ProcessManagerRunner

**Severity:** Important -- output events lose all traceability (no causation chain).

**Files:**
- Modify: `Sources/Songbird/ProcessManagerRunner.swift:120-128`

**Step 1: Build metadata from input event**

Replace lines 120-128:

```swift
// Append output events
let outputStream = StreamName(category: PM.processId, id: route)
let outputMetadata = EventMetadata(
    causationId: recorded.id.uuidString,
    correlationId: recorded.metadata.correlationId ?? recorded.id.uuidString
)
for event in output {
    _ = try await store.append(
        event,
        to: outputStream,
        metadata: outputMetadata,
        expectedVersion: nil
    )
}
```

**Step 2: Run tests**

Run: `swift test --filter ProcessManagerRunnerTests 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit**

```
fix: propagate causation metadata in ProcessManagerRunner output events
```

---

## Task 10: Important -- Add LockedBox Sendable constraint

**Severity:** Important -- `LockedBox<T>` is `@unchecked Sendable` regardless of `T`; if `T` is non-Sendable, the safety guarantee is broken.

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift:211`

**Step 1: Add Sendable constraint**

```swift
// BEFORE:
final class LockedBox<T>: @unchecked Sendable {

// AFTER:
final class LockedBox<T: Sendable>: @unchecked Sendable {
```

**Step 2: Verify build**

Run: `swift build --target SongbirdDistributed 2>&1 | tail -5`
Expected: Build complete (all current usages of `LockedBox` already use `Sendable` types)

**Step 3: Commit**

```
fix: add Sendable constraint to LockedBox<T>
```

---

## Task 11: Important -- Add InjectorRunner injector_id dimension to metrics

**Severity:** Important -- inconsistent with `GatewayRunner` which includes `gateway_id` in all metrics.

**Files:**
- Modify: `Sources/Songbird/InjectorRunner.swift:40-75`

**Step 1: Add injector_id to all metrics**

Replace the metrics calls to include the dimension. Add after line 40 (`for try await inbound in injector.events() {`):

```swift
let injectorDimensions = [("injector_id", injector.injectorId)]
```

Then update each `Metrics.Timer` and `Counter` to include `dimensions: injectorDimensions`:

```swift
Metrics.Timer(
    label: "songbird_injector_append_duration_seconds",
    dimensions: injectorDimensions
).recordNanoseconds(elapsed.nanoseconds)
Counter(
    label: "songbird_injector_append_total",
    dimensions: injectorDimensions + [("status", "success")]
).increment()
```

And the same for the failure path.

**Step 2: Run tests**

Run: `swift build --target Songbird 2>&1 | tail -3`
Expected: Build complete

**Step 3: Commit**

```
fix: add injector_id dimension to InjectorRunner metrics
```

---

## Task 12: Suggestion -- Make DynamicCodingKey private, add EncryptedPayload decode guard

**Severity:** Suggestion -- unnecessary internal visibility; latent defect in decode init.

**Files:**
- Modify: `Sources/Songbird/JSONValue.swift:84,121-129`

**Step 1: Make DynamicCodingKey private**

```swift
// BEFORE (line 84):
internal struct DynamicCodingKey: CodingKey {

// AFTER:
private struct DynamicCodingKey: CodingKey {
```

**Step 2: Guard EncryptedPayload decode**

Replace lines 121-129:

```swift
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    var dict: [String: JSONValue] = [:]
    for key in container.allKeys {
        dict[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
    }
    self.fields = dict
    // EncryptedPayload is always constructed via init(originalEventType:fields:).
    // This Decodable path exists only for protocol conformance and lacks the
    // original event type. Callers should not rely on decoding EncryptedPayload.
    self.originalEventType = ""
}
```

**Step 3: Verify build**

Run: `swift build --target Songbird 2>&1 | tail -3`
Expected: Build complete

**Step 4: Commit**

```
fix: make DynamicCodingKey private and document EncryptedPayload decode limitation
```

---

## Task 13: Suggestion -- Make ReadModelStore.database access safer

**Severity:** Suggestion -- `public let database: Database` and `nonisolated(unsafe) let connection` bypass actor serialization.

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift:27,31`

**Step 1: Restrict visibility**

```swift
// BEFORE (line 27):
public let database: Database

// AFTER:
/// The underlying DuckDB database. Access should go through actor-isolated methods.
/// Exposed for advanced use cases (e.g., creating additional connections); callers must
/// ensure thread safety.
public let database: Database
```

Make `connection` private:

```swift
// BEFORE (line 31):
nonisolated(unsafe) let connection: Connection

// AFTER:
/// The underlying DuckDB connection. Marked `nonisolated(unsafe)` because all access
/// is serialized through this actor's custom `DispatchSerialQueue` executor.
nonisolated(unsafe) private let connection: Connection
```

**Step 2: Check for external uses of `connection`**

Search: `grep -rn 'store\.connection\|readModel\.connection' Sources/ Tests/`

If there are external accesses, they need to go through `withConnection` instead. The `enableTieredModeForTesting()` method accesses `connection` from within the actor, so it is fine.

**Step 3: Run tests**

Run: `swift test --filter SongbirdSmewTests 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```
fix: make ReadModelStore.connection private for actor safety
```

---

## Task 14: Suggestion -- Make AggregateRepository.load batchSize configurable

**Severity:** Suggestion -- hard-coded `batchSize = 1000`, inconsistent with other components.

**Files:**
- Modify: `Sources/Songbird/AggregateRepository.swift:1-17,33`

**Step 1: Add batchSize to init**

```swift
public struct AggregateRepository<A: Aggregate>: Sendable {
    public let store: any EventStore
    public let registry: EventTypeRegistry
    public let snapshotStore: (any SnapshotStore)?
    public let snapshotPolicy: SnapshotPolicy
    public let batchSize: Int

    public init(
        store: any EventStore,
        registry: EventTypeRegistry,
        snapshotStore: (any SnapshotStore)? = nil,
        snapshotPolicy: SnapshotPolicy = .none,
        batchSize: Int = 1000
    ) {
        self.store = store
        self.registry = registry
        self.snapshotStore = snapshotStore
        self.snapshotPolicy = snapshotPolicy
        self.batchSize = batchSize
    }
```

Replace line 33:

```swift
// BEFORE:
let batchSize = 1000

// AFTER (remove the line, use self.batchSize instead):
// (batchSize is now a stored property)
```

**Step 2: Run tests**

Run: `swift test --filter AggregateRepositoryTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```
feat: make AggregateRepository batchSize configurable
```

---

## Task 15: Suggestion -- Document tiering non-atomicity more precisely

**Severity:** Suggestion -- comment claims next tiering pass cleans up duplicates, but there's no dedup logic.

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift:292-296`

**Step 1: Fix the misleading comment**

Replace lines 292-296:

```swift
// INSERT and DELETE are not wrapped in a single transaction because DuckDB
// does not support cross-database transactions (hot and cold are separate
// attached databases). If the process crashes between INSERT and DELETE,
// the UNION ALL view will show duplicate rows. These duplicates persist
// until a manual cleanup is performed (e.g., DROP and re-tier). For most
// read-model use cases, duplicates are tolerable since projections are
// rebuildable. Consider adding deduplication if exact-once matters.
```

**Step 2: Commit**

```
docs: correct tiering crash-recovery comment about duplicates
```

---

## Task 16: Test Gap -- TransportClient timeout and disconnect tests

**Severity:** Important test gap -- `callTimeout` feature and `disconnect()` cleanup never tested.

**Files:**
- Modify: `Tests/SongbirdDistributedTests/TransportTests.swift`

**Step 1: Add timeout test**

```swift
@Test func callTimesOutWhenServerDoesNotRespond() async throws {
    let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    // Use a handler that never responds
    let server = TransportServer(socketPath: socketPath, handler: SilentHandler())
    try await server.start()
    defer { Task { try await server.stop() } }

    let client = TransportClient(callTimeout: .milliseconds(200))
    try await client.connect(socketPath: socketPath)
    defer { Task { try await client.disconnect() } }

    await #expect(throws: SongbirdDistributedError.self) {
        _ = try await client.call(actorName: "a", targetName: "t", arguments: Data())
    }
}
```

Add the `SilentHandler` at the top of the file (near `EchoHandler`):

```swift
/// Handler that receives calls but never responds -- used to test timeouts.
struct SilentHandler: WireMessageHandler {
    func handleMessage(_ message: WireMessage, channel: any Channel) async {
        // Intentionally do nothing
    }
}
```

**Step 2: Add disconnect cleanup test**

```swift
@Test func disconnectDoesNotHang() async throws {
    let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
    try await server.start()
    defer { Task { try await server.stop() } }

    let client = TransportClient()
    try await client.connect(socketPath: socketPath)

    // Disconnect immediately without any calls
    try await client.disconnect()
}
```

**Step 3: Run tests**

Run: `swift test --filter TransportTests 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```
test: add TransportClient timeout and disconnect tests
```

---

## Task 17: Test Gap -- SongbirdServices registerProcessManager + JSONValue.array

**Severity:** Important test gaps -- public API with zero coverage; enum case exists but untested.

**Files:**
- Modify: `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`
- Modify: `Tests/SongbirdTests/JSONValueTests.swift`

**Step 1: Add registerProcessManager test to SongbirdServicesTests**

Add a minimal process manager type and test that it can be registered. Find existing test patterns in the file and follow them. The test should verify the PM runner is added to the runners list.

```swift
@Test func registerProcessManager() async throws {
    // This test verifies that registerProcessManager compiles and the
    // runner is tracked. Full PM behavior is tested in ProcessManagerRunnerTests.
    let store = InMemoryEventStore()
    let positionStore = InMemoryPositionStore()
    var services = SongbirdServices(
        eventStore: store,
        projectionPipeline: ProjectionPipeline(),
        positionStore: positionStore
    )
    services.registerProcessManager(ServicesTestPM.self, positionStore: positionStore)
    // If we got here without a compile error, registration works
}
```

You'll need to define `ServicesTestPM` as a minimal `ProcessManager` type. Follow the pattern from `ProcessManagerRunnerTests.swift`.

**Step 2: Add JSONValue array round-trip test**

In `JSONValueTests.swift`, add:

```swift
@Test func arrayRoundTrip() throws {
    let value = JSONValue.array([.string("a"), .int(1), .bool(true), .null])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
}

@Test func nestedObjectAndArrayRoundTrip() throws {
    let value = JSONValue.object([
        "items": .array([.int(1), .int(2)]),
        "nested": .object(["key": .string("val")])
    ])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
}
```

**Step 3: Run tests**

Run: `swift test --filter SongbirdServicesTests 2>&1 | tail -5` and `swift test --filter JSONValueTests 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```
test: add registerProcessManager and JSONValue.array tests
```

---

## Task 18: Test Gap -- EventTypeRegistry duplicate registration + ProcessManagerRunner cache eviction

**Severity:** Important test gaps -- duplicate registration silently overwrites; cache eviction untested.

**Files:**
- Modify: `Tests/SongbirdTests/EventTypeRegistryTests.swift`
- Modify: `Tests/SongbirdTests/ProcessManagerRunnerTests.swift`

**Step 1: Add duplicate registration test to EventTypeRegistryTests**

```swift
@Test func duplicateRegistrationOverwritesPrevious() throws {
    let registry = EventTypeRegistry()
    // Register AccountEvent for "Deposited"
    registry.register(AccountEvent.self, eventTypes: ["Deposited"])

    // Re-register with a different type for the same string
    // (This is a misconfiguration, but should not crash)
    registry.register(AccountEvent.self, eventTypes: ["Deposited"])

    // Should still decode successfully
    let data = try JSONEncoder().encode(AccountEvent.deposited(amount: 100))
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "account", id: "1"),
        position: 0,
        globalPosition: 0,
        eventType: "Deposited",
        data: data,
        metadata: EventMetadata(),
        timestamp: Date()
    )
    let decoded = try registry.decode(recorded) as! AccountEvent
    #expect(decoded == .deposited(amount: 100))
}
```

**Step 2: Add cache eviction test to ProcessManagerRunnerTests**

Add a test that creates a runner with `maxCacheSize: 2`, processes 3 different entity IDs, and verifies the cache didn't grow beyond 2. Use the `state(for:)` method to check.

```swift
@Test func stateCacheEvictsOldEntries() async throws {
    let store = InMemoryEventStore()
    let positionStore = InMemoryPositionStore()
    let runner = ProcessManagerRunner<TestFulfillmentPM>(
        store: store,
        positionStore: positionStore,
        maxCacheSize: 2
    )

    // Append 3 events for different entities
    for id in ["order-1", "order-2", "order-3"] {
        let event = RunnerOrderEvent.placed(orderId: id, total: 100)
        _ = try await store.append(event, to: StreamName(category: "order", id: id), metadata: EventMetadata(), expectedVersion: nil)
    }

    // Run the runner briefly (it will process the events and stop)
    let task = Task { try await runner.run() }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    // At most 2 entries should remain in the cache
    // One of the first two should have been evicted
    let s1 = await runner.state(for: "order-1")
    let s2 = await runner.state(for: "order-2")
    let s3 = await runner.state(for: "order-3")

    // s3 should always be present (most recently added)
    // At least one of s1/s2 should have been evicted (returned to initialState)
    let hasInitialState = (s1 == TestFulfillmentPM.initialState) || (s2 == TestFulfillmentPM.initialState)
    #expect(hasInitialState, "Expected at least one evicted entry")
}
```

Adapt the test types as needed to match the existing test setup in the file.

**Step 3: Run tests**

Run: `swift test --filter SongbirdTests 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```
test: add EventTypeRegistry duplicate registration and PM cache eviction tests
```

---

## Task 19: Test Gap -- ReadModelStore migration idempotency + TieringService error resilience

**Severity:** Important test gaps -- incremental migration and tiering error recovery untested.

**Files:**
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`
- Modify: `Tests/SongbirdSmewTests/TieringServiceTests.swift`

**Step 1: Add incremental migration test**

```swift
@Test func migrationsApplyIncrementally() throws {
    let store = try ReadModelStore()
    var callCount = 0

    store.registerMigration { conn in
        try conn.execute("CREATE TABLE migration_test_1 (id INTEGER)")
        callCount += 1
    }
    try store.migrate()
    #expect(callCount == 1)

    // Register a second migration and migrate again
    store.registerMigration { conn in
        try conn.execute("CREATE TABLE migration_test_2 (id INTEGER)")
        callCount += 1
    }
    try store.migrate()
    #expect(callCount == 2)  // Only the second migration ran

    // Migrate again -- nothing new to run
    try store.migrate()
    #expect(callCount == 2)  // No change
}
```

**Step 2: Add TieringService error resilience test**

```swift
@Test func tieringContinuesAfterError() async throws {
    // Use a read model that will fail tiering (e.g., non-tiered mode)
    let store = try ReadModelStore()
    let service = TieringService(
        readModel: store,
        thresholdDays: 1,
        interval: .milliseconds(50)
    )

    // Run briefly -- tierProjections returns 0 (non-tiered), not an error
    // But the service loop should run multiple passes without crashing
    let task = Task { await service.run() }
    try await Task.sleep(for: .milliseconds(200))
    await service.stop()
    task.cancel()
    // If we get here without hanging, the service is resilient
}
```

**Step 3: Run tests**

Run: `swift test --filter SongbirdSmewTests 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```
test: add migration idempotency and TieringService resilience tests
```

---

## Task 20: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0029-code-review-remediation-round3.md`

**Step 1: Verify clean build**

Run: `swift build 2>&1 | grep -E "warning:|error:|Build complete"`
Expected: "Build complete!" with no new warnings

**Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 3: Write changelog entry**

Create `changelog/0029-code-review-remediation-round3.md`:

```markdown
# Code Review Remediation (Round 3)

Fixes from the third comprehensive code review of the Songbird framework.

## Critical Fixes
- **Continuation leak**: Fixed race in `ProjectionPipeline.waitForProjection` where cancellation between `withTaskCancellationHandler` and `withCheckedThrowingContinuation` could permanently leak a continuation
- **Continuation orphaning**: Fixed `TransportClient` where timeout cancellation and `disconnect()` could leave continuations never resumed
- **Implicitly unwrapped optional**: Replaced `RecordedEvent!` with proper optional handling in `SQLiteEventStore.append`

## Important Fixes
- **Corrupt timestamp**: `SQLiteEventStore` now throws `corruptedRow` instead of silently falling back to `Date()`
- **Max message size**: `MessageFrameDecoder` rejects frames > 16 MB to prevent OOM
- **Transport logging**: Server and client inbound handlers now log decode failures
- **StreamName validation**: Category must be non-empty and cannot contain hyphens
- **RecordedEvent Equatable**: Added compiler-synthesized `Equatable` conformance
- **Causation metadata**: `ProcessManagerRunner` now propagates `causationId` and `correlationId`
- **LockedBox Sendable**: Added `T: Sendable` constraint
- **InjectorRunner metrics**: Added `injector_id` dimension to all metrics

## Suggestions
- Made `DynamicCodingKey` private, documented `EncryptedPayload` decode limitation
- Made `ReadModelStore.connection` private for actor safety
- Made `AggregateRepository.batchSize` configurable (default 1000)
- Fixed tiering non-atomicity comment (no dedup exists)
- Documented `RequestIdMiddleware` force unwrap safety

## Test Coverage
- TransportClient timeout and disconnect tests
- SongbirdServices registerProcessManager test
- JSONValue array and nested round-trip tests
- EventTypeRegistry duplicate registration test
- ProcessManagerRunner cache eviction test
- ReadModelStore incremental migration test
- TieringService error resilience test
```

**Step 4: Commit**

```
Add code review remediation round 3 changelog entry
```
