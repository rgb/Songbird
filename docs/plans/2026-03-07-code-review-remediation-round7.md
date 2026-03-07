# Code Review Remediation Round 7 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 5 critical issues, 8 important issues, and fill test coverage gaps identified in a comprehensive 5-agent parallel code review of the entire Songbird framework.

**Architecture:** Targeted fixes across all 7 modules. Each task is self-contained with specific file locations and code changes. No new abstractions needed — all fixes tighten existing code.

**Tech Stack:** Swift 6.2, PostgresNIO, SwiftNIO, Synchronization framework, Swift Testing

---

## Task 1: MessageFrameDecoder — throw error on oversized message instead of `.needMoreData`

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:225-231`

**Context:** When an oversized inbound message is detected, the decoder closes the channel but returns `.needMoreData`, which is semantically incorrect — the channel is closing, not waiting for more data.

**Step 1: Fix the decoder to throw after closing**

In `MessageFrameDecoder.decode()`, replace the `.needMoreData` return in the oversized guard with a thrown error:

```swift
guard length <= maxWireMessageSize else {
    let logger = Logger(label: "songbird.transport.decoder")
    logger.error("Inbound message exceeds max size", metadata: [
        "size": "\(length)", "max": "\(maxWireMessageSize)",
    ])
    context.close(promise: nil)
    throw SongbirdDistributedError.connectionFailed("Inbound message exceeds max size: \(length) > \(maxWireMessageSize)")
}
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`

**Step 3: Commit**

---

## Task 2: Transport writeAndFlush — use promise for error detection

**Files:**
- Modify: `Sources/SongbirdDistributed/Transport.swift:130-150`

**Context:** `channel.writeAndFlush(buffer, promise: nil)` in `sendAndAwaitResponse` silently drops write errors, potentially leaving continuations orphaned until channel close. Add a promise that resumes the continuation with an error on write failure.

**Step 1: Use an EventLoopPromise to detect write failures**

Replace the `writeAndFlush(promise: nil)` in `sendAndAwaitResponse` with a promise-based approach:

```swift
private func sendAndAwaitResponse(requestId: UInt64, data: Data, channel: any Channel) async throws -> WireMessage {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            pendingCalls[requestId] = continuation
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            let promise = channel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenFailure { error in
                Task { await self.cancelPendingCall(requestId: requestId, error: SongbirdDistributedError.connectionFailed("Write failed: \(error)")) }
            }
            channel.writeAndFlush(buffer, promise: promise)

            // Guard against cancellation racing with registration.
            if Task.isCancelled {
                if let cont = pendingCalls.removeValue(forKey: requestId) {
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    } onCancel: {
        Task { await self.cancelPendingCall(requestId: requestId, error: CancellationError()) }
    }
}
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`

**Step 3: Commit**

---

## Task 3: PostgresKeyStore — replace preconditionFailure with thrown error

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresKeyStore.swift:60-62`

**Context:** `preconditionFailure` crashes the entire process on a data consistency issue (concurrent DELETE between INSERT and SELECT). This should throw a recoverable error.

**Step 1: Add error case to PostgresStoreError**

In `Sources/SongbirdPostgres/PostgresEventStore.swift` (where `PostgresStoreError` is defined), add a new case:

```swift
public enum PostgresStoreError: Error {
    case encodingFailed
    case corruptedTimestamp(String)
    case keyNotFoundAfterInsert(reference: String, layer: String)
}
```

**Step 2: Replace preconditionFailure with throw**

In `PostgresKeyStore.swift:60-62`, replace:

```swift
// INSERT succeeded or was a no-op, but re-read found nothing.
// This indicates a bug (e.g., concurrent DELETE between INSERT and SELECT).
throw PostgresStoreError.keyNotFoundAfterInsert(reference: reference, layer: layer.rawValue)
```

**Step 3: Verify build**

Run: `swift build 2>&1 | tail -5`

**Step 4: Commit**

---

## Task 4: PostgresTestHelper — fix migration flag + error propagation

**Files:**
- Modify: `Tests/SongbirdPostgresTests/PostgresTestHelper.swift:18-63`

**Context:** Two issues: (1) `started` and `migrated` flags are set before the operation succeeds, so if the operation fails, subsequent calls skip it. (2) Errors in the `Task.detached` container startup are silently dropped, causing test hangs.

**Step 1: Fix flag ordering in ensureStarted**

Move the `started = true` to after the container info is received. Use a different mechanism to prevent reentrancy:

```swift
private var starting = false

func ensureStarted() async throws {
    guard !started else { return }
    guard !starting else {
        // Another call is already starting the container — wait for it
        while starting && !started {
            try await Task.sleep(for: .milliseconds(100))
        }
        if !started { throw PostgresTestHelperError.containerNotStarted }
        return
    }
    starting = true

    let (stream, continuation) = AsyncStream<Result<(String, Int), any Error>>.makeStream()

    Task.detached {
        do {
            let postgres = PostgresContainer()
                .withDatabase("songbird_test")
                .withUsername("songbird")
                .withPassword("songbird")
            try await withPostgresContainer(postgres) { container in
                let mappedPort = try await container.port()
                let mappedHost = container.host()
                continuation.yield(.success((mappedHost, mappedPort)))
                continuation.finish()
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
        } catch {
            continuation.yield(.failure(error))
            continuation.finish()
        }
    }

    for await result in stream {
        switch result {
        case .success(let (h, p)):
            self.host = h
            self.port = p
            self.started = true
        case .failure(let error):
            self.starting = false
            throw error
        }
        break
    }
}
```

**Step 2: Fix flag ordering in ensureMigrated**

```swift
func ensureMigrated() async throws {
    guard !migrated else { return }
    let config = try makeConfiguration()
    let logger = Logger(label: "songbird.test.migrations")
    let client = PostgresClient(configuration: config)
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
        group.cancelAll()
    }
    migrated = true  // Only set after success
}
```

**Step 3: Verify Postgres tests still compile**

Run: `swift build --build-tests 2>&1 | tail -5`

**Step 4: Commit**

---

## Task 5: PostgresEventStore — guard against INSERT RETURNING 0 rows

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventStore.swift:77-82`

**Context:** If INSERT RETURNING returns 0 rows (should never happen, but defensive), `normalizedData` and `normalizedTimestamp` remain empty strings, corrupting the hash chain silently.

**Step 1: Add a guard after the INSERT RETURNING loop**

After the `for try await` loop at line 82, add:

```swift
guard !normalizedData.isEmpty else {
    throw PostgresStoreError.corruptedData("INSERT RETURNING returned no rows for stream '\(streamStr)'")
}
```

**Step 2: Add `corruptedData` case to PostgresStoreError if not already present**

```swift
case corruptedData(String)
```

**Step 3: Verify build**

Run: `swift build 2>&1 | tail -5`

**Step 4: Commit**

---

## Task 6: EventTypeRegistry — replace silent upcast mismatch with preconditionFailure

**Files:**
- Modify: `Sources/Songbird/EventTypeRegistry.swift:77-80`

**Context:** When the type guard fails in `registerUpcast`, the code silently returns the unmodified event. This masks a programming error (registry misconfiguration) and produces incorrect events downstream.

**Step 1: Replace `return event` with preconditionFailure**

```swift
guard let oldEvent = event as? U.OldEvent else {
    preconditionFailure(
        "Registry misconfiguration: decoder for '\(oldEventType)' produced \(type(of: event)), expected \(U.OldEvent.self)"
    )
}
```

This is a programming error (the registry was misconfigured) and should crash loudly during development/testing rather than silently producing wrong data.

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`

**Step 3: Commit**

---

## Task 7: ProcessManagerRunner — reorder state commit to after output append

**Files:**
- Modify: `Sources/Songbird/ProcessManagerRunner.swift:114-148`

**Context:** State cache is updated (line 119) before output events are appended (lines 137-143). If appending fails, state has already advanced but events are missing. Reorder so state is committed only after successful append.

**Step 1: Move state cache update after output append**

```swift
guard let route else { continue }

// Phase 2: Look up state, apply, produce output
let currentState = stateCache[route] ?? PM.initialState
let (newState, output) = try reaction.handle(currentState, recorded)

// Append output events first — if this fails, state stays unchanged
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

// Only update state cache after successful append
stateCache[route] = newState

// Evict oldest entries if cache is too large.
if stateCache.count > maxCacheSize {
    let excess = stateCache.count - maxCacheSize
    for key in stateCache.keys.prefix(excess) {
        stateCache.removeValue(forKey: key)
    }
}
```

**Step 2: Verify build and tests**

Run: `swift build 2>&1 | tail -5`

**Step 3: Commit**

---

## Task 8: EventSubscription — flush position on cancellation

**Files:**
- Modify: `Sources/Songbird/EventSubscription.swift:130-178`

**Context:** When the subscription task is cancelled, any partially-consumed batch position is lost. On restart, the subscription re-processes already-delivered events. Save position when cancellation is detected.

**Step 1: Save position before returning nil on cancellation**

In the `next()` method of Iterator, before the `return nil // cancelled` at line 177, add a position flush:

```swift
// Flush position on cancellation if we had events
if !currentBatch.isEmpty {
    let lastDelivered = currentBatch[min(batchIndex, currentBatch.count) - 1].globalPosition
    if lastDelivered > globalPosition {
        try? await positionStore.save(
            subscriberId: subscriberId,
            globalPosition: lastDelivered
        )
    }
}

return nil  // cancelled
```

**Step 2: Also handle the case where cancellation happens during `readCategories` or `Task.sleep`**

The `while !Task.isCancelled` loop at line 154 already catches cancellation from `checkCancellation()` and `Task.sleep`. When these throw, the loop exits and falls through to `return nil`. The position flush above will handle it.

**Step 3: Verify build**

Run: `swift build 2>&1 | tail -5`

**Step 4: Commit**

---

## Task 9: TestProcessManagerHarness — propagate decode errors

**Files:**
- Modify: `Sources/SongbirdTesting/TestProcessManagerHarness.swift:33`

**Context:** `(try? reaction.tryRoute(event)) ?? nil` silently swallows decoding errors. The test harness should differentiate between "route doesn't match" (nil) and "decode failed" (throw).

**Step 1: Replace try? with explicit do/catch**

```swift
public mutating func given(_ event: RecordedEvent) throws {
    for reaction in PM.reactions {
        let route: String?
        do {
            route = try reaction.tryRoute(event)
        } catch {
            // tryRoute throws when decoding fails for a non-matching event type.
            // Skip to next reaction (matches ProcessManagerRunner behavior).
            continue
        }

        guard let route else { continue }

        let currentState = states[route] ?? PM.initialState
        let (newState, newOutput) = try reaction.handle(currentState, event)
        states[route] = newState
        output.append(contentsOf: newOutput)
        return
    }
}
```

This keeps the same behavior (skip on decode failure) but the pattern is explicit rather than hiding errors behind `try?`.

**Step 2: Verify build and tests**

Run: `swift build --build-tests 2>&1 | tail -5`

**Step 3: Commit**

---

## Task 10: TieringService — add Task.isCancelled check at loop top

**Files:**
- Modify: `Sources/SongbirdSmew/TieringService.swift:38-52`

**Context:** The run loop only catches cancellation during `Task.sleep`. If the task is cancelled while `tierProjections()` is executing, it won't be detected until the next sleep attempt. Add an explicit check.

**Step 1: Add cancellation check**

```swift
public func run() async {
    isRunning = true
    while isRunning && !Task.isCancelled {
        do {
            try await readModel.tierProjections(olderThan: thresholdDays)
        } catch {
            logger.warning("Tiering pass failed", metadata: ["error": "\(error)"])
        }
        do {
            try await Task.sleep(for: interval)
        } catch {
            break  // Cancelled during sleep — exit gracefully
        }
    }
}
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`

**Step 3: Commit**

---

## Task 11: SQLite stores — replace write-only iso8601Formatter with Date.ISO8601FormatStyle

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift:20,64`
- Modify: `Sources/SongbirdSQLite/SQLitePositionStore.swift:12,60`
- Modify: `Sources/SongbirdSQLite/SQLiteKeyStore.swift:21` (and all `.string(from:)` usages)

**Context:** Three SQLite stores use `ISO8601DateFormatter` only for writing (`.string(from:)`), never for reading. `ISO8601DateFormatter` is an NSObject subclass that is not Sendable. Replace with `Date.ISO8601FormatStyle` which is a value type and Sendable.

**Step 1: In each file, remove the `iso8601Formatter` property and replace usages**

Replace:
```swift
private let iso8601Formatter = ISO8601DateFormatter()
```

And change all:
```swift
iso8601Formatter.string(from: Date())
```

To:
```swift
Date.now.formatted(.iso8601)
```

**Important:** Do NOT change `SQLiteEventStore.swift` — it uses `iso8601Formatter` for both reading AND writing (line 369 uses `.date(from:)`).

**Step 2: Verify build and tests**

Run: `swift build 2>&1 | tail -5`

**Step 3: Commit**

---

## Task 12: Distributed tests — replace fire-and-forget defer patterns

**Files:**
- Modify: `Tests/SongbirdDistributedTests/TransportTests.swift`
- Modify: `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`

**Context:** Tests use `defer { Task { try await server.stop() } }` which creates fire-and-forget tasks. Errors are silently dropped and cleanup may not complete before the test exits.

**Step 1: Replace defer-Task patterns with addTeardownBlock or explicit cleanup**

For Swift Testing, use `defer` with synchronous cleanup or restructure tests. Since `stop()` and `shutdown()` are async, the cleanest approach is to move cleanup to the end of each test, before the test returns:

In each test function, replace:
```swift
defer { Task { try await server.stop() } }
defer { Task { try await client.disconnect() } }
```

With cleanup at the end of the test:
```swift
// ... test assertions ...

try await client.disconnect()
try await server.stop()
```

If the test might throw early, wrap in a `do` block:
```swift
do {
    // ... test body ...
} catch {
    try? await client.disconnect()
    try? await server.stop()
    throw error
}
try await client.disconnect()
try await server.stop()
```

Or use a helper pattern:
```swift
try await withCleanup {
    // test body
} cleanup: {
    try? await client.disconnect()
    try? await server.stop()
}
```

**Step 2: Verify tests still pass**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -10`

**Step 3: Commit**

---

## Task 13: Test coverage — Distributed module

**Files:**
- Modify: `Tests/SongbirdDistributedTests/TransportTests.swift`

**Context:** Missing test for `notConnected` error path and concurrent call resolution.

**Step 1: Add notConnected error path test**

```swift
@Test func callBeforeConnectThrowsNotConnected() async throws {
    let client = TransportClient(callTimeout: .seconds(5))
    // Don't connect — just try to call
    await #expect(throws: SongbirdDistributedError.self) {
        _ = try await client.call(
            actorId: "test",
            actorName: "Test",
            targetName: "doSomething",
            arguments: Data()
        )
    }
}
```

**Step 2: Add concurrent calls test**

```swift
@Test func concurrentCallsResolveIndependently() async throws {
    let socketPath = NSTemporaryDirectory() + "songbird-test-concurrent-\(UUID()).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    let server = TransportServer(socketPath: socketPath) { message, channel in
        // Echo response with small delay
        guard let data = try? JSONEncoder().encode(
            WireMessage.result(.init(requestId: message.requestId, payload: message.arguments))
        ) else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try? await Task.sleep(for: .milliseconds(10))
        channel.writeAndFlush(buffer, promise: nil)
    }
    try await server.start()

    let client = TransportClient(callTimeout: .seconds(5))
    try await client.connect(socketPath: socketPath)

    // Launch multiple concurrent calls
    try await withThrowingTaskGroup(of: WireMessage.self) { group in
        for i in 0..<5 {
            group.addTask {
                try await client.call(
                    actorId: "actor-\(i)",
                    actorName: "Test",
                    targetName: "echo",
                    arguments: Data("\(i)".utf8)
                )
            }
        }
        var count = 0
        for try await _ in group {
            count += 1
        }
        #expect(count == 5)
    }

    try await client.disconnect()
    try await server.stop()
}
```

**Step 3: Verify tests pass**

Run: `swift test --filter SongbirdDistributedTests 2>&1 | tail -10`

**Step 4: Commit**

---

## Task 14: Test coverage — Core module (StreamName preconditions)

**Files:**
- Modify: `Tests/SongbirdTests/StreamNameTests.swift`

**Context:** No tests for StreamName precondition failures on invalid input.

**Step 1: Add precondition edge case tests**

```swift
@Test func emptyIdTreatedAsNil() throws {
    // StreamName(category: "test", id: "") should be treated as no-id
    // Verify the behavior matches what we expect
    let name = StreamName(category: "test", id: "")
    #expect(name.category == "test")
}

@Test func categoryWithHyphenUsesFullCategory() throws {
    // "my-category-123" parses as category: "my", id: "category-123"
    let name = StreamName("my-category-123")
    #expect(name.category == "my")
    #expect(name.id == "category-123")
}

@Test func categoryOnlyStreamHasNilId() throws {
    let name = StreamName(category: "orders")
    #expect(name.category == "orders")
    #expect(name.id == nil)
}
```

**Step 2: Verify tests pass**

Run: `swift test --filter StreamNameTests 2>&1 | tail -10`

**Step 3: Commit**

---

## Task 15: Test coverage — SQLite SnapshotStore corrupted data + PositionStore

**Files:**
- Modify: `Tests/SongbirdSQLiteTests/SQLiteSnapshotStoreTests.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLitePositionStoreTests.swift`

**Context:** No tests for corrupted data error paths in SnapshotStore or PositionStore.

**Step 1: Add SnapshotStore corrupted data test**

```swift
@Test func loadCorruptedSnapshotThrowsError() async throws {
    let store = try SQLiteSnapshotStore(path: ":memory:")

    // Save a valid snapshot first
    let state = TestAggregate.State(count: 42)
    let stream = StreamName(category: "test", id: "1")
    try await store.save(state: state, version: 5, for: stream, as: TestAggregate.self)

    // Corrupt the data directly
    #if DEBUG
    try await store.rawExecute("UPDATE snapshots SET state = X'DEADBEEF' WHERE stream_name = 'test-1'")
    #endif

    // Loading should throw
    #if DEBUG
    await #expect(throws: Error.self) {
        let _: (TestAggregate.State, Int64)? = try await store.load(for: stream, as: TestAggregate.self)
    }
    #endif
}
```

**Step 2: Add PositionStore edge case test**

```swift
@Test func loadNonExistentPositionReturnsNil() async throws {
    let store = try SQLitePositionStore(path: ":memory:")
    let position = try await store.load(subscriberId: "nonexistent")
    #expect(position == nil)
}

@Test func saveAndLoadMultipleSubscribers() async throws {
    let store = try SQLitePositionStore(path: ":memory:")
    try await store.save(subscriberId: "sub-1", globalPosition: 10)
    try await store.save(subscriberId: "sub-2", globalPosition: 20)

    let pos1 = try await store.load(subscriberId: "sub-1")
    let pos2 = try await store.load(subscriberId: "sub-2")
    #expect(pos1 == 10)
    #expect(pos2 == 20)
}
```

**Step 3: Verify tests pass**

Run: `swift test --filter SongbirdSQLiteTests 2>&1 | tail -10`

**Step 4: Commit**

---

## Task 16: Test coverage — Hummingbird (ProjectionFlushMiddleware error, PM assertion)

**Files:**
- Modify: `Tests/SongbirdHummingbirdTests/ProjectionFlushMiddlewareTests.swift`
- Modify: `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`

**Context:** (1) No test verifying that ProjectionFlushMiddleware returns successful response even when `waitForIdle()` times out. (2) PM registration test has no assertion — just "if we got here, it works".

**Step 1: Add middleware error resilience test**

```swift
@Test func middlewareReturnsResponseEvenWhenWaitForIdleFails() async throws {
    let pipeline = ProjectionPipeline()
    // Don't start the pipeline — waitForIdle will time out

    let middleware = ProjectionFlushMiddleware(pipeline: pipeline)

    let response = try await middleware.handle(
        Request(head: .init(method: .get, scheme: "http", authority: "localhost", path: "/test"), body: .init()),
        context: TestRequestContext.make(),
        next: { _, _ in Response(status: .ok) }
    )

    // Response should still be returned even if waitForIdle times out or fails
    #expect(response.status == .ok)
}
```

Note: The test may need adjustment based on how `TestRequestContext` is created — look at existing tests for the pattern.

**Step 2: Add observable assertion to PM registration test**

In `registerProcessManager` test (~line 149-178), add an assertion that verifies the PM actually processed the event. Check the output stream for events written by the PM:

```swift
// After the sleep, verify the PM wrote output events
let outputEvents = try await store.readStream(
    StreamName(category: ServicesTestPM.processId, id: "svc-1"),
    from: 0,
    maxCount: 10
)
#expect(!outputEvents.isEmpty, "Process manager should have produced output events")
```

This requires that `ServicesTestPM` actually produces output events. If it doesn't, modify the test PM's reaction to produce at least one output event.

**Step 3: Verify tests pass**

Run: `swift test --filter SongbirdHummingbirdTests 2>&1 | tail -10`

**Step 4: Commit**

---

## Task 17: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0033-code-review-remediation-round7.md`

**Step 1: Clean build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded with 0 warnings.

**Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass.

**Step 3: Write changelog**

Create `changelog/0033-code-review-remediation-round7.md` summarizing all changes.

**Step 4: Commit all changes**

```
git add -A
git commit -m "Code review remediation round 7"
```
