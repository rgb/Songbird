# Warbler Distributed Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a multi-executable version of the Warbler demo app using a new `SongbirdDistributed` module that provides cross-process command dispatch via Swift Distributed Actors over Unix domain sockets.

**Architecture:** An API gateway process forwards HTTP requests to domain-specific worker processes via distributed actors. Workers own their domain's full event-sourcing stack (SQLite event store connection + DuckDB read model + projections + subscriptions). Cross-domain coordination flows through the shared event store. A new `SongbirdDistributed` framework module implements a custom `DistributedActorSystem` using NIO-based Unix domain sockets.

**Tech Stack:** Swift 6.2+, Songbird (local path dep), swift-nio (Unix domain sockets), Hummingbird 2, DuckDB/Smew (per-worker read model), SQLite (shared write model), Swift `Distributed` module

**Design doc:** `docs/plans/2026-03-05-warbler-distributed-design.md`

**Prerequisites:** The Warbler monolith domain modules (`WarblerIdentity`, `WarblerCatalog`, `WarblerSubscriptions`, `WarblerAnalytics`) must be complete. They are reused as-is with zero code changes.

---

## Important Context

### Swift Distributed Actors

Swift Distributed Actors (Swift 5.7+, stable) let you define actors whose methods can be called across process boundaries. The language feature provides isolation rules and compiler enforcement; the transport is pluggable via `DistributedActorSystem`.

**Key concepts:**
- `distributed actor` — an actor whose `distributed func` methods can be called remotely
- `distributed func` — a method that gains implicit `async throws` effects when called cross-actor (the network can fail)
- `DistributedActorSystem` — the protocol you implement to provide transport (serialization, networking, dispatch)
- All `distributed func` parameters and return values must conform to the system's `SerializationRequirement` (we use `Codable`)
- `executeDistributedTarget` — stdlib function that handles the receiving side (demangling, argument decoding, method invocation)
- `LocalTestingDistributedActorSystem` — ships with Swift, for testing without networking

### SQLite.swift Transaction API

```swift
// TransactionMode enum:
public enum TransactionMode: String {
    case deferred = "DEFERRED"
    case immediate = "IMMEDIATE"
    case exclusive = "EXCLUSIVE"
}

// Usage:
try db.transaction(.immediate) {
    // All SQL within this block runs inside BEGIN IMMEDIATE...COMMIT
    // On error, automatically rolls back
}
```

### NIO Unix Domain Socket API

```swift
import NIOCore
import NIOPosix

// Server:
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let bootstrap = ServerBootstrap(group: group)
    .childChannelInitializer { channel in
        channel.pipeline.addHandlers(...)
    }
let channel = try await bootstrap.bind(unixDomainSocketPath: "/tmp/my.sock").get()

// Client:
let clientBootstrap = ClientBootstrap(group: group)
    .channelInitializer { channel in
        channel.pipeline.addHandlers(...)
    }
let channel = try await clientBootstrap.connect(unixDomainSocketPath: "/tmp/my.sock").get()
```

### Songbird EventStore Append (the TOCTOU race)

Current code in `Sources/SongbirdSQLite/SQLiteEventStore.swift:86-143`:
```swift
public func append(...) async throws -> RecordedEvent {
    // Line 96: CHECK — reads current version
    let currentVersion = try currentStreamVersion(streamStr)
    // Line 97-103: Validate expectedVersion
    // Line 105-124: Compute position, encode, hash
    // Line 126-129: INSERT — writes event
    // Gap between CHECK and INSERT = TOCTOU race for cross-process access
}
```

Fix: Wrap the entire check-encode-insert sequence in `db.transaction(.immediate) { ... }`.

### Existing Songbird Module Structure

```
Sources/Songbird/            — Core protocols (Event, Aggregate, ProcessManager, Gateway, etc.)
Sources/SongbirdTesting/     — InMemoryEventStore, test harnesses
Sources/SongbirdSQLite/      — SQLiteEventStore, SQLitePositionStore, SQLiteSnapshotStore
Sources/SongbirdSmew/        — ReadModelStore (DuckDB), TieringService
Sources/SongbirdHummingbird/ — SongbirdServices, RouteHelpers, Middleware
```

---

## Task 1: Fix SQLiteEventStore TOCTOU Race

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift:86-143`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Step 1: Write the failing test**

Add a test that exposes the TOCTOU race by using two separate `SQLiteEventStore` actors connected to the same file. One appends with `expectedVersion: -1`, the other also appends with `expectedVersion: -1` to the same stream. Without the fix, both can succeed (race). With the fix, one must throw `VersionConflictError`.

Add to `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`:

```swift
@Test func concurrentAppendFromSeparateConnectionsDetectsConflict() async throws {
    // Two stores sharing the same SQLite file simulate cross-process access
    let tempDir = FileManager.default.temporaryDirectory
    let dbPath = tempDir.appendingPathComponent("songbird-concurrent-test-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let registry = EventTypeRegistry()
    registry.register(AccountEvent.self)

    let store1 = try SQLiteEventStore(path: dbPath, registry: registry)
    let store2 = try SQLiteEventStore(path: dbPath, registry: registry)

    let stream = StreamName(category: "account", id: "abc")

    // First append from store1 should succeed
    _ = try await store1.append(
        AccountEvent.credited(amount: 100),
        to: stream,
        metadata: EventMetadata(),
        expectedVersion: -1
    )

    // Second append from store2 with expectedVersion: -1 should fail
    // because store1 already wrote position 0
    await #expect(throws: VersionConflictError.self) {
        try await store2.append(
            AccountEvent.credited(amount: 200),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: -1
        )
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/greg/Development/Songbird && swift test --filter SQLiteEventStoreTests/concurrentAppendFromSeparateConnectionsDetectsConflict`

Expected: The test may pass or fail depending on timing — the race is non-deterministic. But with `BEGIN IMMEDIATE`, it will always pass reliably.

**Step 3: Implement the fix**

In `Sources/SongbirdSQLite/SQLiteEventStore.swift`, wrap the entire append body in a `db.transaction(.immediate)` block. The `BEGIN IMMEDIATE` acquires a reserved lock at the start, preventing other connections from writing until the transaction commits.

Replace the `append` method body (lines 91–143) with:

```swift
public func append(
    _ event: some Event,
    to stream: StreamName,
    metadata: EventMetadata,
    expectedVersion: Int64?
) async throws -> RecordedEvent {
    let streamStr = stream.description
    let category = stream.category

    var result: RecordedEvent!

    try db.transaction(.immediate) {
        // Optimistic concurrency check (now inside IMMEDIATE transaction — locked)
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
        let iso8601 = iso8601Formatter.string(from: now)
        let eventData = try JSONEncoder().encode(event)
        guard let eventDataString = String(data: eventData, encoding: .utf8) else {
            throw SQLiteEventStoreError.encodingFailed
        }
        let metadataData = try JSONEncoder().encode(metadata)
        guard let metadataString = String(data: metadataData, encoding: .utf8) else {
            throw SQLiteEventStoreError.encodingFailed
        }
        let eventType = event.eventType

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

        result = RecordedEvent(
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

    return result
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/greg/Development/Songbird && swift test --filter SQLiteEventStoreTests`

Expected: All tests pass including the new concurrent test.

**Step 5: Run full test suite**

Run: `cd /Users/greg/Development/Songbird && swift test`

Expected: All tests pass, zero warnings.

**Step 6: Commit**

```bash
git add Sources/SongbirdSQLite/SQLiteEventStore.swift Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift
git commit -m "Fix SQLiteEventStore TOCTOU race with BEGIN IMMEDIATE transaction

Wraps the version-check-then-insert sequence in a BEGIN IMMEDIATE
transaction, acquiring a write lock at the start. This prevents
concurrent connections (cross-process) from reading stale versions."
```

---

## Task 2: SongbirdDistributed Module Setup

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SongbirdDistributed/SongbirdActorID.swift`
- Create: `Sources/SongbirdDistributed/WireProtocol.swift`
- Create: `Tests/SongbirdDistributedTests/SongbirdActorIDTests.swift`

**Step 1: Add swift-nio dependency and SongbirdDistributed module to Package.swift**

Add to `dependencies` array:
```swift
.package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
```

Add to `products` array:
```swift
.library(name: "SongbirdDistributed", targets: ["SongbirdDistributed"]),
```

Add to `targets` array:
```swift
.target(
    name: "SongbirdDistributed",
    dependencies: [
        "Songbird",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
    ]
),

.testTarget(
    name: "SongbirdDistributedTests",
    dependencies: ["SongbirdDistributed", "SongbirdTesting"]
),
```

**Step 2: Create SongbirdActorID**

```swift
// Sources/SongbirdDistributed/SongbirdActorID.swift
import Distributed

/// A process-aware identity for distributed actors in the Songbird system.
///
/// Each actor is identified by the process it lives in (`processName`) and a
/// local name within that process (`actorName`). The process name corresponds
/// to the worker executable (e.g., "identity-worker") and determines which
/// Unix domain socket to route calls to.
public struct SongbirdActorID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The name of the process that owns this actor (e.g., "identity-worker").
    public let processName: String
    /// The local name of the actor within its process (e.g., "command-handler").
    public let actorName: String

    public init(processName: String, actorName: String) {
        self.processName = processName
        self.actorName = actorName
    }

    public var description: String {
        "\(processName)/\(actorName)"
    }
}
```

**Step 3: Create WireProtocol**

Define the message types exchanged over the socket:

```swift
// Sources/SongbirdDistributed/WireProtocol.swift
import Foundation

/// Messages exchanged over the Unix domain socket between gateway and workers.
///
/// All messages are length-prefixed (4-byte big-endian UInt32) followed by a JSON body.
/// Request/response pairs are matched by `requestId`.
enum WireMessage: Codable {
    case call(Call)
    case result(Result)
    case error(ErrorResult)

    struct Call: Codable {
        let requestId: UInt64
        let actorName: String
        let targetName: String
        let arguments: Data
    }

    struct Result: Codable {
        let requestId: UInt64
        let value: Data
    }

    struct ErrorResult: Codable {
        let requestId: UInt64
        let message: String
    }

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum MessageType: String, Codable {
        case call, result, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .call(let call):
            try container.encode(MessageType.call, forKey: .type)
            try container.encode(call, forKey: .payload)
        case .result(let result):
            try container.encode(MessageType.result, forKey: .type)
            try container.encode(result, forKey: .payload)
        case .error(let error):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(error, forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .call:
            self = .call(try container.decode(Call.self, forKey: .payload))
        case .result:
            self = .result(try container.decode(Result.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(ErrorResult.self, forKey: .payload))
        }
    }
}
```

**Step 4: Write tests for SongbirdActorID**

```swift
// Tests/SongbirdDistributedTests/SongbirdActorIDTests.swift
import Testing
@testable import SongbirdDistributed

@Suite("SongbirdActorID")
struct SongbirdActorIDTests {
    @Test func createsWithProcessAndActorName() {
        let id = SongbirdActorID(processName: "identity-worker", actorName: "command-handler")
        #expect(id.processName == "identity-worker")
        #expect(id.actorName == "command-handler")
    }

    @Test func description() {
        let id = SongbirdActorID(processName: "catalog-worker", actorName: "handler")
        #expect(id.description == "catalog-worker/handler")
    }

    @Test func hashableEquality() {
        let a = SongbirdActorID(processName: "w1", actorName: "h1")
        let b = SongbirdActorID(processName: "w1", actorName: "h1")
        let c = SongbirdActorID(processName: "w1", actorName: "h2")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func codableRoundTrip() throws {
        let id = SongbirdActorID(processName: "worker", actorName: "handler")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(SongbirdActorID.self, from: data)
        #expect(decoded == id)
    }
}

@Suite("WireProtocol")
struct WireProtocolTests {
    @Test func callRoundTrip() throws {
        let msg = WireMessage.call(.init(
            requestId: 42,
            actorName: "handler",
            targetName: "greet(name:)",
            arguments: Data("test".utf8)
        ))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        if case .call(let call) = decoded {
            #expect(call.requestId == 42)
            #expect(call.actorName == "handler")
            #expect(call.targetName == "greet(name:)")
        } else {
            Issue.record("Expected .call")
        }
    }

    @Test func resultRoundTrip() throws {
        let msg = WireMessage.result(.init(requestId: 1, value: Data("ok".utf8)))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        if case .result(let result) = decoded {
            #expect(result.requestId == 1)
        } else {
            Issue.record("Expected .result")
        }
    }

    @Test func errorRoundTrip() throws {
        let msg = WireMessage.error(.init(requestId: 1, message: "not found"))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        if case .error(let err) = decoded {
            #expect(err.message == "not found")
        } else {
            Issue.record("Expected .error")
        }
    }
}
```

**Step 5: Create directories and run tests**

```bash
mkdir -p Sources/SongbirdDistributed Tests/SongbirdDistributedTests
```

Run: `cd /Users/greg/Development/Songbird && swift test --filter SongbirdDistributedTests`

Expected: All 7 tests pass.

**Step 6: Run full test suite**

Run: `cd /Users/greg/Development/Songbird && swift test`

Expected: All tests pass, zero warnings.

**Step 7: Commit**

```bash
git add Package.swift Sources/SongbirdDistributed/ Tests/SongbirdDistributedTests/
git commit -m "Add SongbirdDistributed module with actor ID and wire protocol

New framework module for cross-process distributed actor communication.
SongbirdActorID identifies actors by process name + local name.
WireProtocol defines length-prefixed JSON messages for socket transport."
```

---

## Task 3: Invocation Codec (Encoder + Decoder + ResultHandler)

**Files:**
- Create: `Sources/SongbirdDistributed/InvocationEncoder.swift`
- Create: `Sources/SongbirdDistributed/InvocationDecoder.swift`
- Create: `Sources/SongbirdDistributed/ResultHandler.swift`
- Create: `Tests/SongbirdDistributedTests/InvocationCodecTests.swift`

These implement the `DistributedTargetInvocationEncoder`, `DistributedTargetInvocationDecoder`, and `DistributedTargetInvocationResultHandler` protocols required by `DistributedActorSystem`. They serialize/deserialize distributed function arguments using JSON.

**Step 1: Write InvocationEncoder**

```swift
// Sources/SongbirdDistributed/InvocationEncoder.swift
import Distributed
import Foundation

/// Serializes distributed function call arguments into a JSON byte buffer.
///
/// Each argument is JSON-encoded individually and collected into an array.
/// The complete invocation (target name + arguments) is sent as a `WireMessage.Call`.
public struct SongbirdInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable

    var targetName: String = ""
    var arguments: [Data] = []

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        // We don't support generic distributed functions in Songbird.
        // All distributed funcs use concrete Codable types.
    }

    public mutating func recordArgument<Value: Codable>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        let data = try JSONEncoder().encode(argument.value)
        arguments.append(data)
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        // No-op: we transmit errors as strings
    }

    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
        // No-op: return type is known from the target
    }

    public mutating func doneRecording() throws {
        // No-op: arguments are already collected
    }

    /// Serializes all recorded arguments into a single Data blob (JSON array of base64 chunks).
    func encodeArguments() throws -> Data {
        // Encode as array of base64 strings for clean JSON transport
        let base64Args = arguments.map { $0.base64EncodedString() }
        return try JSONEncoder().encode(base64Args)
    }
}
```

**Step 2: Write InvocationDecoder**

```swift
// Sources/SongbirdDistributed/InvocationDecoder.swift
import Distributed
import Foundation

/// Deserializes distributed function call arguments from a JSON byte buffer.
///
/// Arguments are decoded one at a time in the order they were encoded by
/// `SongbirdInvocationEncoder`. Each call to `decodeNextArgument` advances
/// the internal cursor.
public final class SongbirdInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable

    private let argumentChunks: [Data]
    private var index: Int = 0

    public init(data: Data) throws {
        let base64Args = try JSONDecoder().decode([String].self, from: data)
        self.argumentChunks = try base64Args.map { base64 in
            guard let data = Data(base64Encoded: base64) else {
                throw SongbirdDistributedError.invalidArgumentEncoding
            }
            return data
        }
    }

    public func decodeGenericSubstitutions() throws -> [Any.Type] {
        []  // No generic support
    }

    public func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard index < argumentChunks.count else {
            throw SongbirdDistributedError.argumentCountMismatch
        }
        let data = argumentChunks[index]
        index += 1
        return try JSONDecoder().decode(Argument.self, from: data)
    }

    public func decodeErrorType() throws -> Any.Type? {
        nil  // Errors transmitted as strings
    }

    public func decodeReturnType() throws -> Any.Type? {
        nil  // Return type inferred from target
    }
}
```

**Step 3: Write ResultHandler**

```swift
// Sources/SongbirdDistributed/ResultHandler.swift
import Distributed
import Foundation

/// Captures the result of a distributed function invocation on the receiving side.
///
/// After `executeDistributedTarget` completes, the result handler holds either the
/// serialized return value or error message, ready to be sent back as a `WireMessage`.
public final class SongbirdResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable

    /// The serialized return value, or nil if the call was void or threw an error.
    public private(set) var resultData: Data?
    /// The error message if the call threw.
    public private(set) var errorMessage: String?
    /// Whether the call completed successfully (including void returns).
    public private(set) var isSuccess: Bool = false

    public init() {}

    public func onReturn<Success: Codable>(value: Success) async throws {
        resultData = try JSONEncoder().encode(value)
        isSuccess = true
    }

    public func onReturnVoid() async throws {
        resultData = nil
        isSuccess = true
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        errorMessage = String(describing: error)
        isSuccess = false
    }
}
```

**Step 4: Create error types**

```swift
// Add to Sources/SongbirdDistributed/WireProtocol.swift (append at bottom):

/// Errors specific to the SongbirdDistributed module.
public enum SongbirdDistributedError: Error, CustomStringConvertible {
    case actorNotFound(SongbirdActorID)
    case invalidArgumentEncoding
    case argumentCountMismatch
    case remoteCallFailed(String)
    case connectionFailed(String)
    case notConnected(String)

    public var description: String {
        switch self {
        case .actorNotFound(let id): "Actor not found: \(id)"
        case .invalidArgumentEncoding: "Invalid argument encoding (expected base64)"
        case .argumentCountMismatch: "Argument count mismatch during decoding"
        case .remoteCallFailed(let msg): "Remote call failed: \(msg)"
        case .connectionFailed(let msg): "Connection failed: \(msg)"
        case .notConnected(let process): "Not connected to process: \(process)"
        }
    }
}
```

**Step 5: Write tests for the codec**

```swift
// Tests/SongbirdDistributedTests/InvocationCodecTests.swift
import Distributed
import Testing
@testable import SongbirdDistributed

@Suite("InvocationCodec")
struct InvocationCodecTests {
    @Test func encodesAndDecodesStringArgument() throws {
        var encoder = SongbirdInvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "name", name: "name", value: "Alice"))
        try encoder.doneRecording()

        let data = try encoder.encodeArguments()
        let decoder = try SongbirdInvocationDecoder(data: data)
        let decoded: String = try decoder.decodeNextArgument()
        #expect(decoded == "Alice")
    }

    @Test func encodesAndDecodesMultipleArguments() throws {
        var encoder = SongbirdInvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "name", name: "name", value: "Bob"))
        try encoder.recordArgument(RemoteCallArgument(label: "age", name: "age", value: 42))
        try encoder.doneRecording()

        let data = try encoder.encodeArguments()
        let decoder = try SongbirdInvocationDecoder(data: data)
        let name: String = try decoder.decodeNextArgument()
        let age: Int = try decoder.decodeNextArgument()
        #expect(name == "Bob")
        #expect(age == 42)
    }

    @Test func decoderThrowsOnExtraArgument() throws {
        var encoder = SongbirdInvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "x", name: "x", value: 1))
        try encoder.doneRecording()

        let data = try encoder.encodeArguments()
        let decoder = try SongbirdInvocationDecoder(data: data)
        let _: Int = try decoder.decodeNextArgument()
        #expect(throws: SongbirdDistributedError.self) {
            let _: Int = try decoder.decodeNextArgument()
        }
    }

    @Test func resultHandlerCapturesReturnValue() async throws {
        let handler = SongbirdResultHandler()
        try await handler.onReturn(value: "hello")
        #expect(handler.isSuccess)
        let decoded = try JSONDecoder().decode(String.self, from: handler.resultData!)
        #expect(decoded == "hello")
    }

    @Test func resultHandlerCapturesVoid() async throws {
        let handler = SongbirdResultHandler()
        try await handler.onReturnVoid()
        #expect(handler.isSuccess)
        #expect(handler.resultData == nil)
    }

    @Test func resultHandlerCapturesError() async throws {
        let handler = SongbirdResultHandler()
        try await handler.onThrow(error: SongbirdDistributedError.actorNotFound(
            SongbirdActorID(processName: "test", actorName: "test")
        ))
        #expect(!handler.isSuccess)
        #expect(handler.errorMessage != nil)
    }
}
```

**Step 6: Run tests**

Run: `cd /Users/greg/Development/Songbird && swift test --filter SongbirdDistributedTests`

Expected: All tests pass (13 tests: 7 from Task 2 + 6 new).

**Step 7: Commit**

```bash
git add Sources/SongbirdDistributed/ Tests/SongbirdDistributedTests/
git commit -m "Add invocation codec for distributed actor calls

SongbirdInvocationEncoder serializes Codable arguments as base64 JSON.
SongbirdInvocationDecoder deserializes them in order.
SongbirdResultHandler captures return values and errors."
```

---

## Task 4: NIO Transport Layer

**Files:**
- Create: `Sources/SongbirdDistributed/Transport.swift`
- Create: `Tests/SongbirdDistributedTests/TransportTests.swift`

The transport layer provides Unix domain socket server and client using NIO. Messages are length-prefixed (4-byte big-endian UInt32) followed by JSON-encoded `WireMessage`.

**Step 1: Write the Transport implementation**

```swift
// Sources/SongbirdDistributed/Transport.swift
import Foundation
import NIOCore
import NIOPosix

// MARK: - Message Handler Protocol

/// Protocol for handling incoming wire messages (used by the actor system).
public protocol WireMessageHandler: Sendable {
    func handleMessage(_ message: WireMessage, channel: any Channel) async
}

// MARK: - Transport Server

/// A NIO-based Unix domain socket server that accepts connections and dispatches
/// incoming `WireMessage` calls to a `WireMessageHandler`.
public final class TransportServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let handler: any WireMessageHandler
    nonisolated(unsafe) private var serverChannel: (any Channel)?
    private let socketPath: String

    public init(socketPath: String, handler: any WireMessageHandler) {
        self.socketPath = socketPath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.handler = handler
    }

    /// Starts listening on the Unix domain socket.
    public func start() async throws {
        // Remove stale socket file if it exists
        try? FileManager.default.removeItem(atPath: socketPath)

        let handler = self.handler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    MessageFrameDecoder(),
                    MessageFrameEncoder(),
                    ServerInboundHandler(messageHandler: handler),
                ])
            }

        self.serverChannel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
    }

    /// Stops the server and cleans up the socket file.
    public func stop() async throws {
        try await serverChannel?.close()
        try? FileManager.default.removeItem(atPath: socketPath)
        try await group.shutdownGracefully()
    }
}

// MARK: - Transport Client

/// A NIO-based Unix domain socket client that connects to a server and sends
/// `WireMessage` calls, awaiting responses via continuations.
public actor TransportClient {
    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private var pendingCalls: [UInt64: CheckedContinuation<WireMessage, any Error>] = [:]
    private var nextRequestId: UInt64 = 0

    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Connects to a Unix domain socket server.
    public func connect(socketPath: String) async throws {
        let clientHandler = ClientInboundHandler(client: self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    MessageFrameDecoder(),
                    MessageFrameEncoder(),
                    clientHandler,
                ])
            }

        self.channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
    }

    /// Sends a call and waits for the response.
    public func call(actorName: String, targetName: String, arguments: Data) async throws -> WireMessage {
        guard let channel else {
            throw SongbirdDistributedError.notConnected("no connection")
        }

        let requestId = nextRequestId
        nextRequestId += 1

        let message = WireMessage.call(.init(
            requestId: requestId,
            actorName: actorName,
            targetName: targetName,
            arguments: arguments
        ))

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[requestId] = continuation
            let data = try! JSONEncoder().encode(message)
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(NIOAny(buffer), promise: nil)
        }
    }

    /// Called by the inbound handler when a response arrives.
    func receiveResponse(_ message: WireMessage) {
        let requestId: UInt64
        switch message {
        case .result(let r): requestId = r.requestId
        case .error(let e): requestId = e.requestId
        case .call: return  // Clients don't receive calls
        }

        if let continuation = pendingCalls.removeValue(forKey: requestId) {
            continuation.resume(returning: message)
        }
    }

    /// Disconnects from the server.
    public func disconnect() async throws {
        try await channel?.close()
        try await group.shutdownGracefully()
    }
}

// MARK: - NIO Handlers

/// Length-prefixed frame decoder: reads 4-byte big-endian length + payload.
final class MessageFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 4 else { return .needMoreData }

        let lengthIndex = buffer.readerIndex
        guard let length = buffer.getInteger(at: lengthIndex, as: UInt32.self) else {
            return .needMoreData
        }

        let totalLength = 4 + Int(length)
        guard buffer.readableBytes >= totalLength else { return .needMoreData }

        buffer.moveReaderIndex(forwardBy: 4)
        guard let payload = buffer.readSlice(length: Int(length)) else {
            return .needMoreData
        }

        context.fireChannelRead(NIOAny(payload))
        return .continue
    }
}

/// Length-prefixed frame encoder: writes 4-byte big-endian length + payload.
final class MessageFrameEncoder: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let payload = unwrapOutboundIn(data)
        var frame = context.channel.allocator.buffer(capacity: 4 + payload.readableBytes)
        frame.writeInteger(UInt32(payload.readableBytes))
        frame.writeImmutableBuffer(payload)
        context.write(NIOAny(frame), promise: promise)
    }
}

/// Server-side handler: decodes incoming messages and dispatches to the WireMessageHandler.
final class ServerInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let messageHandler: any WireMessageHandler

    init(messageHandler: any WireMessageHandler) {
        self.messageHandler = messageHandler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: Data(bytes)) else { return }

        let channel = context.channel
        let handler = messageHandler
        Task {
            await handler.handleMessage(message, channel: channel)
        }
    }
}

/// Client-side handler: receives responses and forwards them to the TransportClient actor.
final class ClientInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let client: TransportClient

    init(client: TransportClient) {
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: Data(bytes)) else { return }

        Task {
            await client.receiveResponse(message)
        }
    }
}
```

**Step 2: Write transport integration tests**

```swift
// Tests/SongbirdDistributedTests/TransportTests.swift
import Foundation
import NIOCore
import Testing
@testable import SongbirdDistributed

/// Echo handler for testing: echoes calls back as results.
struct EchoHandler: WireMessageHandler {
    func handleMessage(_ message: WireMessage, channel: any Channel) async {
        guard case .call(let call) = message else { return }
        let response = WireMessage.result(.init(
            requestId: call.requestId,
            value: call.arguments  // Echo arguments back as the result
        ))
        guard let data = try? JSONEncoder().encode(response) else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(NIOAny(buffer), promise: nil)
    }
}

@Suite("Transport")
struct TransportTests {
    @Test func clientServerRoundTrip() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
        try await server.start()
        defer { Task { try await server.stop() } }

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)
        defer { Task { try await client.disconnect() } }

        let testData = Data("hello".utf8)
        let response = try await client.call(
            actorName: "test",
            targetName: "echo",
            arguments: testData
        )

        if case .result(let result) = response {
            #expect(result.value == testData)
        } else {
            Issue.record("Expected .result, got \(response)")
        }
    }

    @Test func multipleCallsInSequence() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
        try await server.start()
        defer { Task { try await server.stop() } }

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)
        defer { Task { try await client.disconnect() } }

        for i in 0..<5 {
            let data = Data("msg-\(i)".utf8)
            let response = try await client.call(actorName: "a", targetName: "t", arguments: data)
            if case .result(let result) = response {
                #expect(result.value == data)
            } else {
                Issue.record("Call \(i) failed")
            }
        }
    }
}
```

**Step 3: Run tests**

Run: `cd /Users/greg/Development/Songbird && swift test --filter SongbirdDistributedTests`

Expected: All tests pass (13 from previous + 2 new = 15).

**Step 4: Commit**

```bash
git add Sources/SongbirdDistributed/Transport.swift Tests/SongbirdDistributedTests/TransportTests.swift
git commit -m "Add NIO-based Unix domain socket transport layer

TransportServer listens on a socket and dispatches to a WireMessageHandler.
TransportClient connects and sends calls with continuation-based responses.
Messages use 4-byte big-endian length-prefixed JSON framing."
```

---

## Task 5: SongbirdActorSystem Implementation

**Files:**
- Create: `Sources/SongbirdDistributed/SongbirdActorSystem.swift`
- Create: `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`

This is the core `DistributedActorSystem` implementation that ties everything together.

**Step 1: Write SongbirdActorSystem**

```swift
// Sources/SongbirdDistributed/SongbirdActorSystem.swift
import Distributed
import Foundation
import NIOCore

/// A custom `DistributedActorSystem` for same-machine IPC over Unix domain sockets.
///
/// Each process creates a `SongbirdActorSystem` and binds a Unix domain socket.
/// Workers register local distributed actors. The gateway connects to worker sockets
/// and calls their distributed functions transparently.
///
/// Usage (worker side):
/// ```swift
/// let system = SongbirdActorSystem(processName: "identity-worker")
/// try await system.startServer(socketPath: "/tmp/songbird/identity.sock")
/// let handler = IdentityHandler(actorSystem: system)
/// ```
///
/// Usage (gateway/client side):
/// ```swift
/// let system = SongbirdActorSystem(processName: "gateway")
/// try await system.connect(processName: "identity-worker", socketPath: "/tmp/songbird/identity.sock")
/// let handler = try IdentityHandler.resolve(
///     id: SongbirdActorID(processName: "identity-worker", actorName: "handler"),
///     using: system
/// )
/// let result = try await handler.doSomething()
/// ```
public final class SongbirdActorSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = SongbirdActorID
    public typealias InvocationEncoder = SongbirdInvocationEncoder
    public typealias InvocationDecoder = SongbirdInvocationDecoder
    public typealias ResultHandler = SongbirdResultHandler
    public typealias SerializationRequirement = Codable

    /// The process name for this system instance.
    public let processName: String

    /// Registered local actors, keyed by actor name.
    private let localActors = LockedBox<[String: any DistributedActor]>([:])

    /// Auto-increment counter for actor names when not explicitly assigned.
    private let nextAutoId = LockedBox<Int>(0)

    /// Transport clients connected to remote processes, keyed by process name.
    private let clients = LockedBox<[String: TransportClient]>([:])

    /// Transport server (if this system is a worker).
    private var server: TransportServer?

    public init(processName: String) {
        self.processName = processName
    }

    // MARK: - Server / Client Management

    /// Starts listening for incoming distributed actor calls on a Unix domain socket.
    public func startServer(socketPath: String) async throws {
        let server = TransportServer(socketPath: socketPath, handler: ActorSystemMessageHandler(system: self))
        try await server.start()
        self.server = server
    }

    /// Connects to a remote worker process.
    public func connect(processName: String, socketPath: String) async throws {
        let client = TransportClient()
        try await client.connect(socketPath: socketPath)
        clients.withLock { $0[processName] = client }
    }

    /// Stops the server and disconnects all clients.
    public func shutdown() async throws {
        if let server {
            try await server.stop()
        }
        let allClients = clients.withLock { dict -> [TransportClient] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for client in allClients {
            try await client.disconnect()
        }
    }

    // MARK: - DistributedActorSystem Protocol

    public func resolve<Act>(id: SongbirdActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == SongbirdActorID {
        // Return local actor if it's ours
        if id.processName == processName {
            return localActors.withLock { $0[id.actorName] } as? Act
        }
        // For remote actors, return nil — Swift creates a remote proxy
        return nil
    }

    public func assignID<Act>(_ actorType: Act.Type) -> SongbirdActorID
    where Act: DistributedActor {
        let autoId = nextAutoId.withLock { id -> Int in
            let current = id
            id += 1
            return current
        }
        return SongbirdActorID(processName: processName, actorName: "auto-\(autoId)")
    }

    public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == SongbirdActorID {
        localActors.withLock { $0[actor.id.actorName] = actor }
    }

    public func resignID(_ id: SongbirdActorID) {
        localActors.withLock { $0.removeValue(forKey: id.actorName) }
    }

    public func makeInvocationEncoder() -> SongbirdInvocationEncoder {
        SongbirdInvocationEncoder()
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout SongbirdInvocationEncoder,
        throwing _: Err.Type,
        returning _: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == SongbirdActorID, Err: Error, Res: Codable {
        let id = actor.id
        guard let client = clients.withLock({ $0[id.processName] }) else {
            throw SongbirdDistributedError.notConnected(id.processName)
        }

        let arguments = try invocation.encodeArguments()
        let response = try await client.call(
            actorName: id.actorName,
            targetName: target.identifier,
            arguments: arguments
        )

        switch response {
        case .result(let result):
            return try JSONDecoder().decode(Res.self, from: result.value)
        case .error(let err):
            throw SongbirdDistributedError.remoteCallFailed(err.message)
        case .call:
            throw SongbirdDistributedError.remoteCallFailed("Unexpected call message in response")
        }
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout SongbirdInvocationEncoder,
        throwing _: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == SongbirdActorID, Err: Error {
        let id = actor.id
        guard let client = clients.withLock({ $0[id.processName] }) else {
            throw SongbirdDistributedError.notConnected(id.processName)
        }

        let arguments = try invocation.encodeArguments()
        let response = try await client.call(
            actorName: id.actorName,
            targetName: target.identifier,
            arguments: arguments
        )

        switch response {
        case .result:
            return  // void success
        case .error(let err):
            throw SongbirdDistributedError.remoteCallFailed(err.message)
        case .call:
            throw SongbirdDistributedError.remoteCallFailed("Unexpected call message in response")
        }
    }

    // MARK: - Incoming Call Dispatch

    /// Handles an incoming distributed actor call from the transport layer.
    func handleIncomingCall(actorName: String, targetName: String, arguments: Data) async throws -> (data: Data?, error: String?) {
        guard let actor = localActors.withLock({ $0[actorName] }) else {
            throw SongbirdDistributedError.actorNotFound(
                SongbirdActorID(processName: processName, actorName: actorName)
            )
        }

        var decoder = try SongbirdInvocationDecoder(data: arguments)
        let handler = SongbirdResultHandler()

        try await executeDistributedTarget(
            on: actor,
            target: RemoteCallTarget(targetName),
            invocationDecoder: &decoder,
            handler: handler
        )

        if handler.isSuccess {
            return (data: handler.resultData, error: nil)
        } else {
            return (data: nil, error: handler.errorMessage ?? "Unknown error")
        }
    }
}

// MARK: - LockedBox

/// A simple thread-safe wrapper for mutable state.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Message Handler

/// Bridges incoming wire messages to the actor system's call dispatch.
struct ActorSystemMessageHandler: WireMessageHandler {
    let system: SongbirdActorSystem

    func handleMessage(_ message: WireMessage, channel: any Channel) async {
        guard case .call(let call) = message else { return }

        let response: WireMessage
        do {
            let (data, error) = try await system.handleIncomingCall(
                actorName: call.actorName,
                targetName: call.targetName,
                arguments: call.arguments
            )
            if let error {
                response = .error(.init(requestId: call.requestId, message: error))
            } else {
                response = .result(.init(requestId: call.requestId, value: data ?? Data()))
            }
        } catch {
            response = .error(.init(requestId: call.requestId, message: String(describing: error)))
        }

        guard let responseData = try? JSONEncoder().encode(response) else { return }
        var buffer = channel.allocator.buffer(capacity: responseData.count)
        buffer.writeBytes(responseData)
        channel.writeAndFlush(NIOAny(buffer), promise: nil)
    }
}
```

**Step 2: Write integration tests with a real distributed actor**

```swift
// Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift
import Distributed
import Testing
@testable import SongbirdDistributed

// A simple distributed actor for testing
distributed actor Greeter {
    typealias ActorSystem = SongbirdActorSystem

    distributed func greet(name: String) -> String {
        "Hello, \(name)!"
    }

    distributed func add(a: Int, b: Int) -> Int {
        a + b
    }
}

@Suite("SongbirdActorSystem")
struct SongbirdActorSystemTests {
    @Test func localActorCallWorks() async throws {
        let system = SongbirdActorSystem(processName: "test")
        let greeter = Greeter(actorSystem: system)
        let result = try await greeter.greet(name: "World")
        #expect(result == "Hello, World!")
    }

    @Test func remoteActorCallOverSocket() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        // Worker side
        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)
        defer { Task { try await workerSystem.shutdown() } }

        let greeter = Greeter(actorSystem: workerSystem)
        // Re-register with a known name so the client can resolve it
        let knownId = SongbirdActorID(processName: "worker", actorName: "greeter")
        workerSystem.actorReady(greeter)
        // Override: manually set the known name (the auto-assigned one won't match)
        _ = greeter // keep alive

        // Client side
        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)
        defer { Task { try await clientSystem.shutdown() } }

        // Resolve the remote greeter
        let remoteGreeter = try Greeter.resolve(id: knownId, using: clientSystem)
        let result = try await remoteGreeter.greet(name: "Alice")
        #expect(result == "Hello, Alice!")
    }

    @Test func multipleArgumentsWork() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)
        defer { Task { try await workerSystem.shutdown() } }

        let greeter = Greeter(actorSystem: workerSystem)
        let knownId = SongbirdActorID(processName: "worker", actorName: greeter.id.actorName)

        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)
        defer { Task { try await clientSystem.shutdown() } }

        let remote = try Greeter.resolve(id: knownId, using: clientSystem)
        let result = try await remote.add(a: 3, b: 4)
        #expect(result == 7)
    }

    @Test func unresolvedActorThrowsError() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)
        defer { Task { try await workerSystem.shutdown() } }

        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)
        defer { Task { try await clientSystem.shutdown() } }

        let fakeId = SongbirdActorID(processName: "worker", actorName: "nonexistent")
        let remote = try Greeter.resolve(id: fakeId, using: clientSystem)

        await #expect(throws: SongbirdDistributedError.self) {
            _ = try await remote.greet(name: "Fail")
        }
    }
}
```

**Step 3: Run tests**

Run: `cd /Users/greg/Development/Songbird && swift test --filter SongbirdDistributedTests`

Expected: All tests pass.

**Step 4: Run full test suite**

Run: `cd /Users/greg/Development/Songbird && swift test`

Expected: All tests pass, zero warnings.

**Step 5: Commit**

```bash
git add Sources/SongbirdDistributed/SongbirdActorSystem.swift Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift
git commit -m "Add SongbirdActorSystem — custom DistributedActorSystem for IPC

Implements the full DistributedActorSystem protocol with Unix domain
socket transport. Supports local actor registration, remote resolution,
and cross-process distributed function calls via NIO."
```

---

## Task 6: Changelog + Clean Build

**Files:**
- Create: `changelog/0017-songbird-distributed.md`

**Step 1: Run full test suite and verify clean build**

Run: `cd /Users/greg/Development/Songbird && swift test 2>&1 | tail -5`

Expected: All tests pass, zero warnings.

**Step 2: Write changelog entry**

```markdown
# SongbirdDistributed Module

Adds a new `SongbirdDistributed` module providing cross-process communication for Songbird applications via Swift Distributed Actors over Unix domain sockets.

**Design doc:** `docs/plans/2026-03-05-warbler-distributed-design.md`

## What Changed

### New Module: SongbirdDistributed

Dependencies: `Songbird` + `swift-nio` (NIOCore, NIOPosix)

### New Types

- **`SongbirdActorSystem`** — Custom `DistributedActorSystem` implementation. Workers bind a Unix domain socket and register local distributed actors. Clients connect to worker sockets and call distributed functions transparently.
- **`SongbirdActorID`** — Process-aware actor identity (`processName` + `actorName`). Determines which socket to route calls to.
- **`TransportServer`** — NIO-based Unix domain socket server. Accepts connections and dispatches incoming calls to the actor system.
- **`TransportClient`** — NIO-based Unix domain socket client. Sends calls with continuation-based request/response matching.
- **`SongbirdInvocationEncoder`** — Serializes distributed function arguments as base64-encoded JSON.
- **`SongbirdInvocationDecoder`** — Deserializes arguments in order for `executeDistributedTarget`.
- **`SongbirdResultHandler`** — Captures return values and errors from distributed function invocations.
- **`WireMessage`** — Length-prefixed JSON protocol (Call, Result, Error) for socket communication.

### Prerequisite Fix

- **`SQLiteEventStore.append()`** now uses `BEGIN IMMEDIATE` transaction to prevent TOCTOU race when multiple processes write to the same SQLite file.

## Testing

Unit tests for actor ID, wire protocol, invocation codec. Integration tests for transport layer and full distributed actor calls over real Unix domain sockets.

## Known Limitations

- Unix domain sockets are local-only (no network distribution)
- No service discovery — socket paths configured at startup
- No retry/reconnection logic (MVP)
- No generic distributed function support (concrete Codable types only)

## Files

- `Sources/SongbirdDistributed/SongbirdActorSystem.swift` (new)
- `Sources/SongbirdDistributed/SongbirdActorID.swift` (new)
- `Sources/SongbirdDistributed/Transport.swift` (new)
- `Sources/SongbirdDistributed/WireProtocol.swift` (new)
- `Sources/SongbirdDistributed/InvocationEncoder.swift` (new)
- `Sources/SongbirdDistributed/InvocationDecoder.swift` (new)
- `Sources/SongbirdDistributed/ResultHandler.swift` (new)
- `Sources/SongbirdSQLite/SQLiteEventStore.swift` (modified — BEGIN IMMEDIATE)
- `Tests/SongbirdDistributedTests/*.swift` (new)
```

**Step 3: Commit**

```bash
git add changelog/0017-songbird-distributed.md
git commit -m "Add SongbirdDistributed changelog entry"
```

---

## Task 7: Warbler Distributed Package Scaffold

**Prerequisites:** The Warbler monolith domain modules (`WarblerIdentity`, `WarblerCatalog`, `WarblerSubscriptions`, `WarblerAnalytics`) must exist at `demo/warbler/Sources/`. If they are not yet complete, this task must wait.

**Files:**
- Create: `demo/warbler-distributed/Package.swift`
- Create: `demo/warbler-distributed/Sources/WarblerGateway/main.swift` (placeholder)
- Create: `demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift` (placeholder)
- Create: `demo/warbler-distributed/Sources/WarblerCatalogWorker/main.swift` (placeholder)
- Create: `demo/warbler-distributed/Sources/WarblerSubscriptionsWorker/main.swift` (placeholder)
- Create: `demo/warbler-distributed/Sources/WarblerAnalyticsWorker/main.swift` (placeholder)

**Step 1: Create directory structure**

```bash
mkdir -p demo/warbler-distributed/Sources/{WarblerGateway,WarblerIdentityWorker,WarblerCatalogWorker,WarblerSubscriptionsWorker,WarblerAnalyticsWorker}
```

**Step 2: Write Package.swift**

```swift
// demo/warbler-distributed/Package.swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerDistributed",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../../"),  // Songbird
        .package(path: "../warbler"),  // Warbler domain modules
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Gateway (HTTP → distributed actor calls)

        .executableTarget(
            name: "WarblerGateway",
            dependencies: [
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerIdentity", package: "Warbler"),
                .product(name: "WarblerCatalog", package: "Warbler"),
                .product(name: "WarblerSubscriptions", package: "Warbler"),
                .product(name: "WarblerAnalytics", package: "Warbler"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Workers (domain-specific processes)

        .executableTarget(
            name: "WarblerIdentityWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerIdentity", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerCatalogWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerCatalog", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerSubscriptionsWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerSubscriptions", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerAnalyticsWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerAnalytics", package: "Warbler"),
            ]
        ),
    ]
)
```

**Note:** This Package.swift references the Warbler monolith as a local dependency (`../warbler`). The Warbler monolith's `Package.swift` must export its domain modules as library products. If it doesn't yet, the monolith's `Package.swift` needs `.library(name: "WarblerIdentity", targets: ["WarblerIdentity"])` etc. added to its `products` array.

**Step 3: Write placeholder main.swift files**

Each placeholder just prints a message. They'll be replaced with real implementations in later tasks.

```swift
// demo/warbler-distributed/Sources/WarblerGateway/main.swift
print("WarblerGateway — placeholder")
```

```swift
// demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift
print("WarblerIdentityWorker — placeholder")
```

```swift
// demo/warbler-distributed/Sources/WarblerCatalogWorker/main.swift
print("WarblerCatalogWorker — placeholder")
```

```swift
// demo/warbler-distributed/Sources/WarblerSubscriptionsWorker/main.swift
print("WarblerSubscriptionsWorker — placeholder")
```

```swift
// demo/warbler-distributed/Sources/WarblerAnalyticsWorker/main.swift
print("WarblerAnalyticsWorker — placeholder")
```

**Step 4: Verify the package resolves**

```bash
cd demo/warbler-distributed && swift package resolve
```

Expected: Package resolution succeeds (or fails if Warbler monolith isn't complete — in that case, note this and move on).

**Step 5: Commit**

```bash
cd /Users/greg/Development/Songbird
git add demo/warbler-distributed/
git commit -m "Add Warbler Distributed package scaffold

Five executables: WarblerGateway + 4 domain workers.
Depends on Songbird framework and Warbler monolith domain modules."
```

---

## Task 8: Worker Infrastructure — Shared Bootstrap Pattern

**Files:**
- Create: `demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift` (replace placeholder)

We implement one worker fully (Identity), then replicate the pattern for the other three domains.

**Step 1: Write the Identity Worker**

The worker creates its event store connection, read model, projection pipeline, registers domain components, creates the distributed command handler actor, and runs.

```swift
// demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift
import Distributed
import Foundation
import Songbird
import SongbirdDistributed
import SongbirdSQLite
import SongbirdSmew
import WarblerIdentity

// MARK: - Distributed Command Handler

distributed actor IdentityCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    let services: SongbirdServices
    let repository: AggregateRepository<UserAggregate>
    let readModel: ReadModelStore

    init(
        actorSystem: SongbirdActorSystem,
        services: SongbirdServices,
        repository: AggregateRepository<UserAggregate>,
        readModel: ReadModelStore
    ) {
        self.actorSystem = actorSystem
        self.services = services
        self.repository = repository
        self.readModel = readModel
    }

    // MARK: - Commands

    distributed func registerUser(email: String, displayName: String) async throws -> String {
        let userId = UUID().uuidString
        let command = RegisterUser(email: email, displayName: displayName)
        let stream = StreamName(category: UserAggregate.category, id: userId)
        let events = try RegisterUserHandler.handle(command, given: UserAggregate.initialState)
        for event in events {
            let recorded = try await services.eventStore.append(
                event, to: stream, metadata: EventMetadata(), expectedVersion: nil
            )
            await services.projectionPipeline.enqueue(recorded)
        }
        return userId
    }

    distributed func updateProfile(userId: String, displayName: String) async throws {
        let command = UpdateProfile(displayName: displayName)
        try await executeAndProject(
            command, on: userId, metadata: EventMetadata(),
            using: UpdateProfileHandler.self,
            repository: repository, services: services
        )
    }

    distributed func deactivateUser(userId: String) async throws {
        let command = DeactivateUser()
        try await executeAndProject(
            command, on: userId, metadata: EventMetadata(),
            using: DeactivateUserHandler.self,
            repository: repository, services: services
        )
    }

    // MARK: - Queries

    distributed func getUser(id: String) async throws -> UserDTO? {
        try await readModel.queryFirst(UserDTO.self) {
            "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: id)"
        }
    }
}

/// DTO for the user query result (must be Codable for distributed transport).
public struct UserDTO: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let email: String
    public let isActive: Bool
}

// MARK: - Bootstrap

@main
struct WarblerIdentityWorkerApp {
    static func main() async throws {
        // Parse arguments (simple positional for demo)
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("Usage: WarblerIdentityWorker <sqlite-path> <duckdb-path> <socket-path>")
            return
        }
        let sqlitePath = args[1]
        let duckdbPath = args[2]
        let socketPath = args[3]

        // Event type registry
        let registry = EventTypeRegistry()
        registry.register(UserEvent.self)

        // Event store (shared SQLite file)
        let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)

        // Read model (per-worker DuckDB)
        let readModel = try ReadModelStore(path: duckdbPath)

        // Position store
        let positionStore = try SQLitePositionStore(path: sqlitePath)

        // Projection pipeline
        let pipeline = ProjectionPipeline()

        // Register projector
        let userProjector = UserProjector(readModel: readModel)
        await readModel.registerMigration(UserProjector.migration)
        try await readModel.migrate()

        // Services
        var services = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        services.registerProjector(userProjector)

        // Aggregate repository
        let repository = AggregateRepository<UserAggregate>(
            store: eventStore, registry: registry
        )

        // Distributed actor system
        let system = SongbirdActorSystem(processName: "identity-worker")
        try await system.startServer(socketPath: socketPath)

        // Create and register the command handler
        let handler = IdentityCommandHandler(
            actorSystem: system,
            services: services,
            repository: repository,
            readModel: readModel
        )
        _ = handler  // Keep alive

        print("Identity worker started on \(socketPath)")

        // Run services (blocks until cancelled)
        try await services.run()
    }
}
```

**Note:** This code depends on `WarblerIdentity` module types (`UserAggregate`, `UserEvent`, `RegisterUser`, `RegisterUserHandler`, `UpdateProfile`, `UpdateProfileHandler`, `DeactivateUser`, `DeactivateUserHandler`, `UserProjector`). These must exist in the Warbler monolith. If they don't yet, adapt the imports and type names to match what the monolith actually implements.

**Step 2: Build to check compilation**

```bash
cd demo/warbler-distributed && swift build --target WarblerIdentityWorker 2>&1 | head -20
```

Expected: Compiles (or shows specific type mismatches if Warbler monolith uses different names — fix accordingly).

**Step 3: Commit**

```bash
cd /Users/greg/Development/Songbird
git add demo/warbler-distributed/Sources/WarblerIdentityWorker/
git commit -m "Implement WarblerIdentityWorker with distributed command handler

Full worker: SQLiteEventStore (shared), ReadModelStore (per-worker),
projection pipeline, and distributed actor for identity commands/queries."
```

---

## Task 9: Remaining Workers (Catalog, Subscriptions, Analytics)

**Files:**
- Modify: `demo/warbler-distributed/Sources/WarblerCatalogWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerSubscriptionsWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerAnalyticsWorker/main.swift`

Each worker follows the same pattern as the Identity worker: SQLiteEventStore + ReadModelStore + pipeline + distributed actor command handler. The differences are the domain-specific types and which components (projectors, process managers, gateways, injectors) are registered.

**Step 1: Write CatalogWorker** (similar to IdentityWorker but with VideoAggregate, event versioning)

**Step 2: Write SubscriptionsWorker** (with ProcessManager, Gateway — no aggregate)

**Step 3: Write AnalyticsWorker** (with Injector, tiered storage, snapshots)

Each follows the identical bootstrap pattern from Task 8, substituting domain-specific types. The key difference per worker:

| Worker | Aggregate | Projector | Process Manager | Gateway | Injector | Special |
|--------|-----------|-----------|-----------------|---------|----------|---------|
| Identity | `UserAggregate` | `UserProjector` | — | — | — | — |
| Catalog | `VideoAggregate` | `VideoCatalogProjector` | — | — | — | Event versioning upcast |
| Subscriptions | — | `SubscriptionProjector` | `SubscriptionLifecycleProcess` | `EmailNotificationGateway` | — | PM + Gateway |
| Analytics | `ViewCountAggregate` | `PlaybackAnalyticsProjector` | — | — | `PlaybackInjector` | Tiered storage, snapshots |

**Step 4: Build all workers**

```bash
cd demo/warbler-distributed && swift build
```

**Step 5: Commit**

```bash
cd /Users/greg/Development/Songbird
git add demo/warbler-distributed/Sources/
git commit -m "Implement Catalog, Subscriptions, and Analytics workers

Each worker follows the shared bootstrap pattern with domain-specific
aggregates, projectors, process managers, gateways, and injectors."
```

---

## Task 10: Gateway Executable

**Files:**
- Modify: `demo/warbler-distributed/Sources/WarblerGateway/main.swift`

The gateway is a Hummingbird app that routes HTTP requests to worker distributed actors.

**Step 1: Write the Gateway**

```swift
// demo/warbler-distributed/Sources/WarblerGateway/main.swift
import Distributed
import Foundation
import Hummingbird
import Songbird
import SongbirdDistributed
import SongbirdHummingbird

@main
struct WarblerGatewayApp {
    static func main() async throws {
        // Parse config
        let port = 8080
        let identitySocket = "/tmp/songbird/identity.sock"
        let catalogSocket = "/tmp/songbird/catalog.sock"
        let subscriptionsSocket = "/tmp/songbird/subscriptions.sock"
        let analyticsSocket = "/tmp/songbird/analytics.sock"

        // Create actor system and connect to all workers
        let system = SongbirdActorSystem(processName: "gateway")
        try await system.connect(processName: "identity-worker", socketPath: identitySocket)
        try await system.connect(processName: "catalog-worker", socketPath: catalogSocket)
        try await system.connect(processName: "subscriptions-worker", socketPath: subscriptionsSocket)
        try await system.connect(processName: "analytics-worker", socketPath: analyticsSocket)

        // Resolve remote command handlers
        let identity = try IdentityCommandHandler.resolve(
            id: SongbirdActorID(processName: "identity-worker", actorName: "command-handler"),
            using: system
        )
        let catalog = try CatalogCommandHandler.resolve(
            id: SongbirdActorID(processName: "catalog-worker", actorName: "command-handler"),
            using: system
        )
        let subscriptions = try SubscriptionsCommandHandler.resolve(
            id: SongbirdActorID(processName: "subscriptions-worker", actorName: "command-handler"),
            using: system
        )
        let analytics = try AnalyticsCommandHandler.resolve(
            id: SongbirdActorID(processName: "analytics-worker", actorName: "command-handler"),
            using: system
        )

        // Configure Hummingbird router
        let router = Router(context: SongbirdRequestContext.self)

        // Identity routes
        router.post("/users") { request, context in
            struct Body: Decodable { let email: String; let displayName: String }
            let body = try await request.decode(as: Body.self, context: context)
            let userId = try await identity.registerUser(email: body.email, displayName: body.displayName)
            struct Created: ResponseEncodable { let userId: String }
            return Created(userId: userId)
        }

        router.get("/users/{id}") { _, context in
            let id = try context.parameters.require("id")
            guard let user = try await identity.getUser(id: id) else {
                throw HTTPError(.notFound)
            }
            return user
        }

        // ... (remaining routes follow the same pattern, forwarding to the
        //      appropriate worker's distributed command handler)

        // Start Hummingbird
        let app = Application(router: router)
        try await app.runService()
    }
}
```

**Note:** The gateway needs to import the distributed actor types from the worker modules, OR define protocol-based interfaces. For the demo, the simplest approach is to define the distributed actor types in a shared module, or to use the `@Resolvable` macro (Swift 6.0+). The exact approach depends on how the domain modules are structured.

**Step 2: Build**

```bash
cd demo/warbler-distributed && swift build --target WarblerGateway
```

**Step 3: Commit**

```bash
cd /Users/greg/Development/Songbird
git add demo/warbler-distributed/Sources/WarblerGateway/
git commit -m "Implement WarblerGateway — HTTP router forwarding to workers

Routes HTTP requests to domain-specific worker processes via distributed
actor calls. Same API surface as the Warbler monolith."
```

---

## Task 11: Launch Script + Final Verification

**Files:**
- Create: `demo/warbler-distributed/launch.sh`

**Step 1: Write the launch script**

```bash
#!/usr/bin/env bash
# launch.sh — Starts all Warbler Distributed processes
set -euo pipefail

# Default paths
DATA_DIR="${DATA_DIR:-./data}"
SOCKET_DIR="${SOCKET_DIR:-/tmp/songbird}"
SQLITE_PATH="${DATA_DIR}/songbird.sqlite"

# Create directories
mkdir -p "$DATA_DIR" "$SOCKET_DIR"

echo "Starting Warbler Distributed..."
echo "  SQLite: $SQLITE_PATH"
echo "  Sockets: $SOCKET_DIR"

# Build if needed
swift build 2>/dev/null || true

# Start workers
.build/debug/WarblerIdentityWorker "$SQLITE_PATH" "$DATA_DIR/identity.duckdb" "$SOCKET_DIR/identity.sock" &
PIDS+=($!)
.build/debug/WarblerCatalogWorker "$SQLITE_PATH" "$DATA_DIR/catalog.duckdb" "$SOCKET_DIR/catalog.sock" &
PIDS+=($!)
.build/debug/WarblerSubscriptionsWorker "$SQLITE_PATH" "$DATA_DIR/subscriptions.duckdb" "$SOCKET_DIR/subscriptions.sock" &
PIDS+=($!)
.build/debug/WarblerAnalyticsWorker "$SQLITE_PATH" "$DATA_DIR/analytics.duckdb" "$SOCKET_DIR/analytics.sock" &
PIDS+=($!)

# Wait for sockets to be created
sleep 1

# Start gateway
.build/debug/WarblerGateway &
PIDS+=($!)

echo "All processes started. Gateway at http://localhost:8080"
echo "PIDs: ${PIDS[*]}"

# Wait for any process to exit
wait -n
echo "A process exited. Shutting down..."

# Clean up
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
wait
echo "All processes stopped."
```

**Step 2: Make executable**

```bash
chmod +x demo/warbler-distributed/launch.sh
```

**Step 3: Verify everything builds**

```bash
cd demo/warbler-distributed && swift build
```

**Step 4: Commit**

```bash
cd /Users/greg/Development/Songbird
git add demo/warbler-distributed/launch.sh
git commit -m "Add launch script for Warbler Distributed

Starts all 5 processes (4 workers + gateway) with configurable
data and socket directories."
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Fix SQLiteEventStore TOCTOU race | `SQLiteEventStore.swift`, tests |
| 2 | SongbirdDistributed module setup | `Package.swift`, `SongbirdActorID.swift`, `WireProtocol.swift` |
| 3 | Invocation codec | `InvocationEncoder.swift`, `InvocationDecoder.swift`, `ResultHandler.swift` |
| 4 | NIO transport layer | `Transport.swift`, transport tests |
| 5 | SongbirdActorSystem | `SongbirdActorSystem.swift`, system tests |
| 6 | Changelog + clean build | `changelog/0017-songbird-distributed.md` |
| 7 | Warbler Distributed scaffold | `demo/warbler-distributed/Package.swift`, placeholders |
| 8 | Identity Worker | Full worker with distributed command handler |
| 9 | Remaining workers | Catalog, Subscriptions, Analytics workers |
| 10 | Gateway executable | Hummingbird HTTP router |
| 11 | Launch script | `launch.sh` |
