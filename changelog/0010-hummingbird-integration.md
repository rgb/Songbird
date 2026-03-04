# Hummingbird Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a `SongbirdHummingbird` module providing composable building blocks for integrating Songbird with Hummingbird 2: a services container with lifecycle management, a request context with tracing, two middleware components, and route helpers.

**Architecture:** Building blocks only — no application builder, no auth, no error mapping. Users compose their own Hummingbird app and wire in Songbird's components. `SongbirdServices` is a mutable struct (matching Hummingbird's `Router` pattern) that conforms to `Service` for lifecycle management, running the projection pipeline and process manager runners in a task group. Route helpers (`appendAndProject`, `executeAndProject`) handle the append-then-enqueue pattern.

**Tech Stack:** Swift 6.2+, Hummingbird 2, swift-service-lifecycle 2, Songbird core types, HummingbirdTesting for tests

**Design doc:** `docs/plans/2026-03-04-hummingbird-integration-design.md`

---

## Task 1: Package.swift + Module Structure

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SongbirdHummingbird/SongbirdHummingbird.swift` (placeholder re-export)

**Step 1: Update Package.swift**

Add the Hummingbird dependency, the `SongbirdHummingbird` product/target, and the test target:

```swift
// In products array, add:
.library(name: "SongbirdHummingbird", targets: ["SongbirdHummingbird"]),

// In dependencies array, add:
.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),

// In targets array, add:

// MARK: - Hummingbird Integration

.target(
    name: "SongbirdHummingbird",
    dependencies: [
        "Songbird",
        .product(name: "Hummingbird", package: "hummingbird"),
    ]
),

// In test targets, add:
.testTarget(
    name: "SongbirdHummingbirdTests",
    dependencies: [
        "SongbirdHummingbird",
        "SongbirdTesting",
        .product(name: "HummingbirdTesting", package: "hummingbird"),
    ]
),
```

**Step 2: Create placeholder source file**

Create `Sources/SongbirdHummingbird/SongbirdHummingbird.swift`:

```swift
// SongbirdHummingbird — Hummingbird 2 integration for Songbird
```

**Step 3: Verify the package resolves and builds**

Run: `swift build --target SongbirdHummingbird 2>&1 | tail -5`
Expected: Build succeeds (resolving Hummingbird and its dependencies).

**Step 4: Commit**

```bash
git add Package.swift Sources/SongbirdHummingbird/SongbirdHummingbird.swift
git commit -m "Add SongbirdHummingbird module with Hummingbird 2 dependency"
```

---

## Task 2: SongbirdRequestContext

A minimal `RequestContext` conformance with a `requestId` field for request tracing.

**Files:**
- Create: `Sources/SongbirdHummingbird/SongbirdRequestContext.swift`
- Create: `Tests/SongbirdHummingbirdTests/SongbirdRequestContextTests.swift`

**Step 1: Write the tests**

```swift
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SongbirdHummingbird

@Suite("SongbirdRequestContext")
struct SongbirdRequestContextTests {
    @Test func requestIdIsNilByDefault() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.get("/test") { _, context -> String in
            let hasRequestId = context.requestId != nil
            return "\(hasRequestId)"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            #expect(String(buffer: response.body) == "false")
        }
    }

    @Test func contextWorksWithRouter() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.get("/hello") { _, _ -> String in
            "hello"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/hello", method: .get)
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "hello")
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdRequestContextTests 2>&1 | tail -10`
Expected: FAIL — `SongbirdRequestContext` not found.

**Step 3: Implement SongbirdRequestContext**

Create `Sources/SongbirdHummingbird/SongbirdRequestContext.swift`:

```swift
import Foundation
import Hummingbird

public struct SongbirdRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public var requestId: String?

    public init(source: Source) {
        self.coreContext = .init(source: source)
        self.requestId = nil
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdRequestContextTests 2>&1 | tail -10`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Sources/SongbirdHummingbird/SongbirdRequestContext.swift Tests/SongbirdHummingbirdTests/SongbirdRequestContextTests.swift
git commit -m "Add SongbirdRequestContext with requestId field"
```

---

## Task 3: RequestIdMiddleware

Extracts `X-Request-ID` from the request or generates a UUID, sets it on the context, and echoes it in the response header. Typed to `SongbirdRequestContext`.

**Files:**
- Create: `Sources/SongbirdHummingbird/RequestIdMiddleware.swift`
- Create: `Tests/SongbirdHummingbirdTests/RequestIdMiddlewareTests.swift`

**Step 1: Write the tests**

```swift
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SongbirdHummingbird

@Suite("RequestIdMiddleware")
struct RequestIdMiddlewareTests {
    @Test func extractsExistingRequestId() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.get("/test") { _, context -> String in
            context.requestId ?? "none"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/test",
                method: .get,
                headers: [.init("X-Request-ID")!: "my-trace-123"]
            )
            #expect(String(buffer: response.body) == "my-trace-123")
            #expect(response.headers[.init("X-Request-ID")!] == "my-trace-123")
        }
    }

    @Test func generatesUUIDWhenHeaderMissing() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.get("/test") { _, context -> String in
            context.requestId ?? "none"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            let body = String(buffer: response.body)
            #expect(body != "none")
            // Verify it's a valid UUID
            #expect(UUID(uuidString: body) != nil)
            // Verify response header matches
            #expect(response.headers[.init("X-Request-ID")!] == body)
        }
    }

    @Test func echoesRequestIdInResponse() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.get("/test") { _, _ -> String in "ok" }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/test",
                method: .get,
                headers: [.init("X-Request-ID")!: "echo-me"]
            )
            #expect(response.headers[.init("X-Request-ID")!] == "echo-me")
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter RequestIdMiddlewareTests 2>&1 | tail -10`
Expected: FAIL — `RequestIdMiddleware` not found.

**Step 3: Implement RequestIdMiddleware**

Create `Sources/SongbirdHummingbird/RequestIdMiddleware.swift`:

```swift
import Foundation
import HTTPTypes
import Hummingbird

public struct RequestIdMiddleware: RouterMiddleware {
    public typealias Context = SongbirdRequestContext

    static let headerName = HTTPField.Name("X-Request-ID")!

    public init() {}

    public func handle(
        _ request: Request,
        context: SongbirdRequestContext,
        next: (Request, SongbirdRequestContext) async throws -> Response
    ) async throws -> Response {
        var context = context
        context.requestId = request.headers[Self.headerName] ?? UUID().uuidString
        var response = try await next(request, context)
        response.headers[Self.headerName] = context.requestId
        return response
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter RequestIdMiddlewareTests 2>&1 | tail -10`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Sources/SongbirdHummingbird/RequestIdMiddleware.swift Tests/SongbirdHummingbirdTests/RequestIdMiddlewareTests.swift
git commit -m "Add RequestIdMiddleware for X-Request-ID header handling"
```

---

## Task 4: ProjectionFlushMiddleware

Generic over any `RequestContext`. After the route handler completes, waits for the projection pipeline to catch up. Only used in tests for read-after-write consistency. Timeout errors are silently swallowed.

**Files:**
- Create: `Sources/SongbirdHummingbird/ProjectionFlushMiddleware.swift`
- Create: `Tests/SongbirdHummingbirdTests/ProjectionFlushMiddlewareTests.swift`

**Step 1: Write the tests**

```swift
import Foundation
import Hummingbird
import HummingbirdTesting
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

/// A projector that records applied events for verification.
private actor CountingProjector: Projector {
    let projectorId = "counting"
    private(set) var count = 0

    func apply(_ event: RecordedEvent) async throws {
        count += 1
    }
}

@Suite("ProjectionFlushMiddleware")
struct ProjectionFlushMiddlewareTests {
    @Test func waitsForPipelineAfterHandler() async throws {
        let pipeline = ProjectionPipeline()
        let projector = CountingProjector()
        await pipeline.register(projector)
        let pipelineTask = Task { await pipeline.run() }

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware {
            ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline)
        }
        router.get("/test") { _, _ -> String in
            // Enqueue an event during the request
            await pipeline.enqueue(try RecordedEvent(event: FlushTestEvent()))
            return "ok"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            #expect(response.status == .ok)
        }

        // After the middleware's flush, the projector should have processed the event
        let count = await projector.count
        #expect(count == 1)

        await pipeline.stop()
        await pipelineTask.value
    }

    @Test func worksWithAnyRequestContext() async throws {
        // Verify it compiles and runs with BasicRequestContext (not just SongbirdRequestContext)
        let pipeline = ProjectionPipeline()
        let pipelineTask = Task { await pipeline.run() }

        let router = Router(context: BasicRequestContext.self)
        router.addMiddleware {
            ProjectionFlushMiddleware<BasicRequestContext>(pipeline: pipeline)
        }
        router.get("/test") { _, _ -> String in "ok" }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            #expect(response.status == .ok)
        }

        await pipeline.stop()
        await pipelineTask.value
    }
}

private struct FlushTestEvent: Event {
    var eventType: String { "FlushTestEvent" }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectionFlushMiddlewareTests 2>&1 | tail -10`
Expected: FAIL — `ProjectionFlushMiddleware` not found.

**Step 3: Implement ProjectionFlushMiddleware**

Create `Sources/SongbirdHummingbird/ProjectionFlushMiddleware.swift`:

```swift
import Hummingbird
import Songbird

public struct ProjectionFlushMiddleware<Context: RequestContext>: RouterMiddleware {
    let pipeline: ProjectionPipeline

    public init(pipeline: ProjectionPipeline) {
        self.pipeline = pipeline
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        try? await pipeline.waitForIdle()
        return response
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectionFlushMiddlewareTests 2>&1 | tail -10`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Sources/SongbirdHummingbird/ProjectionFlushMiddleware.swift Tests/SongbirdHummingbirdTests/ProjectionFlushMiddlewareTests.swift
git commit -m "Add ProjectionFlushMiddleware for test-time read-after-write consistency"
```

---

## Task 5: Route Helper — appendAndProject

A free function that appends a single event to the store and enqueues it to the projection pipeline. This is the fundamental write operation in a Songbird route handler.

**Files:**
- Create: `Sources/SongbirdHummingbird/RouteHelpers.swift`
- Create: `Tests/SongbirdHummingbirdTests/RouteHelperTests.swift`

**Step 1: Write the tests**

These tests use `InMemoryEventStore` and `ProjectionPipeline` directly — no HTTP needed.

```swift
import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

private struct TestEvent: Event {
    var eventType: String { "TestEvent" }
    let value: Int
}

@Suite("RouteHelpers")
struct RouteHelperTests {
    // MARK: - appendAndProject

    @Test func appendAndProjectStoresEvent() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector()
        await pipeline.register(projector)
        let pipelineTask = Task { await pipeline.run() }

        let recorded = try await appendAndProject(
            TestEvent(value: 42),
            to: StreamName(category: "test", id: "1"),
            metadata: EventMetadata(traceId: "trace-1"),
            services: SongbirdServices(
                eventStore: store,
                projectionPipeline: pipeline,
                positionStore: InMemoryPositionStore(),
                eventRegistry: EventTypeRegistry()
            )
        )

        // Event is persisted
        #expect(recorded.eventType == "TestEvent")
        #expect(recorded.streamName == StreamName(category: "test", id: "1"))
        #expect(recorded.metadata.traceId == "trace-1")

        // Event is projected
        try await pipeline.waitForIdle()
        let count = await projector.appliedEvents.count
        #expect(count == 1)

        await pipeline.stop()
        await pipelineTask.value
    }

    @Test func appendAndProjectRespectsExpectedVersion() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let pipelineTask = Task { await pipeline.run() }
        let services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        let stream = StreamName(category: "test", id: "1")

        // First append succeeds with expectedVersion -1 (empty stream)
        _ = try await appendAndProject(
            TestEvent(value: 1),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: -1,
            services: services
        )

        // Second append with wrong expected version fails
        await #expect(throws: VersionConflictError.self) {
            try await appendAndProject(
                TestEvent(value: 2),
                to: stream,
                metadata: EventMetadata(),
                expectedVersion: -1,
                services: services
            )
        }

        await pipeline.stop()
        await pipelineTask.value
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter RouteHelperTests 2>&1 | tail -10`
Expected: FAIL — `appendAndProject` not found.

**Step 3: Implement appendAndProject**

Create `Sources/SongbirdHummingbird/RouteHelpers.swift`:

```swift
import Songbird

/// Appends a single event to the event store and enqueues it to the projection pipeline.
///
/// This is the fundamental write operation for Songbird route handlers. It atomically persists
/// the event (with optimistic concurrency control via `expectedVersion`) and then hands it to
/// the projection pipeline for asynchronous read-model updates.
///
/// - Parameters:
///   - event: The domain event to append.
///   - stream: The target stream name.
///   - metadata: Event metadata (trace ID, causation, etc.).
///   - expectedVersion: Optional optimistic concurrency check. Pass `nil` to skip.
///   - services: The `SongbirdServices` container.
/// - Returns: The `RecordedEvent` as persisted by the store.
@discardableResult
public func appendAndProject(
    _ event: some Event,
    to stream: StreamName,
    metadata: EventMetadata,
    expectedVersion: Int64? = nil,
    services: SongbirdServices
) async throws -> RecordedEvent {
    let recorded = try await services.eventStore.append(
        event,
        to: stream,
        metadata: metadata,
        expectedVersion: expectedVersion
    )
    await services.projectionPipeline.enqueue(recorded)
    return recorded
}
```

**Step 4: Write SongbirdServices stub**

The route helpers need `SongbirdServices` to exist. Create `Sources/SongbirdHummingbird/SongbirdServices.swift` with the minimal struct (full Service conformance comes in Task 7):

```swift
import Songbird

public struct SongbirdServices: Sendable {
    public let eventStore: any EventStore
    public let projectionPipeline: ProjectionPipeline
    public let positionStore: any PositionStore
    public let eventRegistry: EventTypeRegistry

    public init(
        eventStore: any EventStore,
        projectionPipeline: ProjectionPipeline,
        positionStore: any PositionStore,
        eventRegistry: EventTypeRegistry
    ) {
        self.eventStore = eventStore
        self.projectionPipeline = projectionPipeline
        self.positionStore = positionStore
        self.eventRegistry = eventRegistry
    }
}
```

**Step 5: Run tests to verify they pass**

Run: `swift test --filter RouteHelperTests 2>&1 | tail -10`
Expected: All tests PASS.

**Step 6: Commit**

```bash
git add Sources/SongbirdHummingbird/RouteHelpers.swift Sources/SongbirdHummingbird/SongbirdServices.swift Tests/SongbirdHummingbirdTests/RouteHelperTests.swift
git commit -m "Add appendAndProject route helper and SongbirdServices struct"
```

---

## Task 6: Route Helper — executeAndProject

Executes a command via `AggregateRepository` and enqueues all resulting events to the projection pipeline.

**Files:**
- Modify: `Sources/SongbirdHummingbird/RouteHelpers.swift`
- Modify: `Tests/SongbirdHummingbirdTests/RouteHelperTests.swift`

**Step 1: Write test domain types and tests**

Add to `RouteHelperTests.swift`:

```swift
// Domain types for executeAndProject tests
private enum CounterEvent: Event, Equatable {
    case incremented(amount: Int)

    var eventType: String {
        switch self {
        case .incremented: "Incremented"
        }
    }
}

private enum CounterAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var count: Int
    }
    typealias Failure = CounterError

    static let category = "counter"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: CounterEvent) -> State {
        switch event {
        case .incremented(let amount):
            State(count: state.count + amount)
        }
    }
}

private enum CounterError: Error {
    case negativeAmount
}

private struct IncrementCounter: Command {
    let amount: Int
    var commandType: String { "IncrementCounter" }
}

private enum IncrementHandler: CommandHandler {
    typealias Agg = CounterAggregate
    typealias Cmd = IncrementCounter

    static func handle(
        _ command: IncrementCounter,
        given state: CounterAggregate.State
    ) throws(CounterAggregate.Failure) -> [CounterEvent] {
        guard command.amount > 0 else { throw .negativeAmount }
        return [.incremented(amount: command.amount)]
    }
}
```

Then add these tests inside the `RouteHelperTests` struct:

```swift
    // MARK: - executeAndProject

    @Test func executeAndProjectStoresAndProjectsEvents() async throws {
        let registry = EventTypeRegistry()
        registry.register(CounterEvent.self, eventTypes: ["Incremented"])
        let store = InMemoryEventStore(registry: registry)
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector()
        await pipeline.register(projector)
        let pipelineTask = Task { await pipeline.run() }
        let services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: registry
        )
        let repository = AggregateRepository<CounterAggregate>(
            store: store, registry: registry
        )

        let recorded = try await executeAndProject(
            IncrementCounter(amount: 5),
            on: "counter-1",
            metadata: EventMetadata(traceId: "trace-1"),
            using: IncrementHandler.self,
            repository: repository,
            services: services
        )

        #expect(recorded.count == 1)
        #expect(recorded[0].eventType == "Incremented")

        // Event is projected
        try await pipeline.waitForIdle()
        let count = await projector.appliedEvents.count
        #expect(count == 1)

        await pipeline.stop()
        await pipelineTask.value
    }

    @Test func executeAndProjectPropagatesCommandFailure() async throws {
        let registry = EventTypeRegistry()
        registry.register(CounterEvent.self, eventTypes: ["Incremented"])
        let store = InMemoryEventStore(registry: registry)
        let pipeline = ProjectionPipeline()
        let pipelineTask = Task { await pipeline.run() }
        let services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: registry
        )
        let repository = AggregateRepository<CounterAggregate>(
            store: store, registry: registry
        )

        await #expect(throws: CounterError.self) {
            try await executeAndProject(
                IncrementCounter(amount: -1),
                on: "counter-1",
                metadata: EventMetadata(),
                using: IncrementHandler.self,
                repository: repository,
                services: services
            )
        }

        await pipeline.stop()
        await pipelineTask.value
    }
```

**Step 2: Run tests to verify the new tests fail**

Run: `swift test --filter RouteHelperTests 2>&1 | tail -10`
Expected: FAIL — `executeAndProject` not found.

**Step 3: Implement executeAndProject**

Add to `Sources/SongbirdHummingbird/RouteHelpers.swift`:

```swift
/// Executes a command via an `AggregateRepository` and enqueues all resulting events
/// to the projection pipeline.
///
/// This is the command-handling write operation for Songbird route handlers. It loads the
/// aggregate, validates and executes the command (with optimistic concurrency), then hands
/// the resulting events to the projection pipeline.
///
/// - Parameters:
///   - command: The command to execute.
///   - id: The aggregate entity ID.
///   - metadata: Event metadata (trace ID, causation, etc.).
///   - handler: The `CommandHandler` type that validates and produces events.
///   - repository: The aggregate repository to load state and append events.
///   - services: The `SongbirdServices` container.
/// - Returns: The recorded events as persisted by the store.
@discardableResult
public func executeAndProject<H: CommandHandler>(
    _ command: H.Cmd,
    on id: String,
    metadata: EventMetadata,
    using handler: H.Type,
    repository: AggregateRepository<H.Agg>,
    services: SongbirdServices
) async throws -> [RecordedEvent] {
    let recorded = try await repository.execute(
        command,
        on: id,
        metadata: metadata,
        using: handler
    )
    for event in recorded {
        await services.projectionPipeline.enqueue(event)
    }
    return recorded
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter RouteHelperTests 2>&1 | tail -10`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Sources/SongbirdHummingbird/RouteHelpers.swift Tests/SongbirdHummingbirdTests/RouteHelperTests.swift
git commit -m "Add executeAndProject route helper for command execution"
```

---

## Task 7: SongbirdServices — Registration + Service Conformance

Complete `SongbirdServices` with projector/process manager registration and `Service` conformance. The `run()` method orchestrates the projection pipeline and all registered process manager runners in a task group. Cancellation stops everything.

**Files:**
- Modify: `Sources/SongbirdHummingbird/SongbirdServices.swift`
- Create: `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`

**Step 1: Write the tests**

```swift
import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

private struct ServicesTestEvent: Event {
    var eventType: String { "ServicesTestEvent" }
}

@Suite("SongbirdServices")
struct SongbirdServicesTests {
    @Test func registerProjectorAndRunPipeline() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        services.registerProjector(projector)

        let serviceTask = Task { try await services.run() }

        // Append and enqueue an event
        let recorded = try await store.append(
            ServicesTestEvent(),
            to: StreamName(category: "test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        await pipeline.enqueue(recorded)
        try await pipeline.waitForIdle()

        // Projector received the event
        let count = await projector.appliedEvents.count
        #expect(count == 1)

        // Cancel to stop the service
        serviceTask.cancel()
        try? await serviceTask.value
    }

    @Test func cancellationStopsService() async throws {
        let pipeline = ProjectionPipeline()
        let services = SongbirdServices(
            eventStore: InMemoryEventStore(),
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )

        let serviceTask = Task { try await services.run() }

        // Give it a moment to start
        try await Task.sleep(for: .milliseconds(50))

        serviceTask.cancel()
        // Should complete without hanging
        try? await serviceTask.value
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdServicesTests 2>&1 | tail -10`
Expected: FAIL — `registerProjector` and `run()` not found.

**Step 3: Implement full SongbirdServices**

Replace `Sources/SongbirdHummingbird/SongbirdServices.swift`:

```swift
import Songbird

/// A container for Songbird's core services, providing lifecycle management for the
/// projection pipeline and process manager runners.
///
/// `SongbirdServices` is a mutable struct (matching Hummingbird's `Router` pattern) that
/// you configure before starting the application. Register projectors and process managers,
/// then pass it to a `ServiceGroup` or `Application` (it conforms to `Service`).
///
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
/// let app = Application(router: router, services: [services])
/// try await app.runService()
/// ```
public struct SongbirdServices: Sendable {
    public let eventStore: any EventStore
    public let projectionPipeline: ProjectionPipeline
    public let positionStore: any PositionStore
    public let eventRegistry: EventTypeRegistry

    private var projectors: [any Projector] = []
    private var runnerFactories: [@Sendable () async throws -> Void] = []

    public init(
        eventStore: any EventStore,
        projectionPipeline: ProjectionPipeline,
        positionStore: any PositionStore,
        eventRegistry: EventTypeRegistry
    ) {
        self.eventStore = eventStore
        self.projectionPipeline = projectionPipeline
        self.positionStore = positionStore
        self.eventRegistry = eventRegistry
    }

    // MARK: - Registration

    /// Registers a projector to receive events from the projection pipeline.
    public mutating func registerProjector(_ projector: any Projector) {
        projectors.append(projector)
    }

    /// Registers a process manager to run as a background subscription.
    ///
    /// The runner is created when `run()` is called and executes in the task group alongside
    /// the projection pipeline.
    public mutating func registerProcessManager<PM: ProcessManager>(
        _ type: PM.Type,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        let store = self.eventStore
        let positionStore = self.positionStore
        runnerFactories.append {
            let runner = ProcessManagerRunner<PM>(
                store: store,
                positionStore: positionStore,
                batchSize: batchSize,
                tickInterval: tickInterval
            )
            try await runner.run()
        }
    }

    // MARK: - Lifecycle

    /// Starts the projection pipeline and all registered process manager runners.
    ///
    /// This method blocks until cancelled. Cancellation propagates to all child tasks:
    /// - The pipeline is stopped via `pipeline.stop()`
    /// - Process manager runners are cancelled (their subscription polling loop exits)
    public func run() async throws {
        // Register projectors with the pipeline
        for projector in projectors {
            await projectionPipeline.register(projector)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Start the projection pipeline with cancellation handling
            group.addTask {
                await withTaskCancellationHandler {
                    await self.projectionPipeline.run()
                } onCancel: {
                    Task { await self.projectionPipeline.stop() }
                }
            }

            // Start all process manager runners
            for factory in runnerFactories {
                group.addTask {
                    try await factory()
                }
            }

            // Wait for all tasks (they run until cancelled)
            try await group.waitForAll()
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdServicesTests 2>&1 | tail -10`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Sources/SongbirdHummingbird/SongbirdServices.swift Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift
git commit -m "Add SongbirdServices with projector/PM registration and Service lifecycle"
```

---

## Task 8: Integration Test — Full HTTP Request Cycle

An end-to-end test that exercises the full flow: HTTP request → command execution → event store → projection pipeline → read model → query.

**Files:**
- Create: `Tests/SongbirdHummingbirdTests/IntegrationTests.swift`

**Step 1: Write the integration test**

```swift
import Foundation
import Hummingbird
import HummingbirdTesting
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

// Domain types for integration test
private enum BalanceEvent: Event, Equatable {
    case deposited(amount: Int)

    var eventType: String {
        switch self {
        case .deposited: "Deposited"
        }
    }
}

private enum BalanceAggregate: Aggregate {
    struct State: Sendable, Equatable { var balance: Int }
    typealias Failure = Never

    static let category = "account"
    static let initialState = State(balance: 0)

    static func apply(_ state: State, _ event: BalanceEvent) -> State {
        switch event {
        case .deposited(let amount):
            State(balance: state.balance + amount)
        }
    }
}

private struct Deposit: Command {
    let amount: Int
    var commandType: String { "Deposit" }
}

private enum DepositHandler: CommandHandler {
    typealias Agg = BalanceAggregate
    typealias Cmd = Deposit

    static func handle(
        _ command: Deposit,
        given state: BalanceAggregate.State
    ) throws(Never) -> [BalanceEvent] {
        [.deposited(amount: command.amount)]
    }
}

/// A projector that tracks account balances (simulates a read model).
private actor BalanceProjector: Projector {
    let projectorId = "balance"
    private var balances: [String: Int] = [:]

    func apply(_ event: RecordedEvent) async throws {
        guard event.eventType == "Deposited",
              let decoded = try? event.decode(BalanceEvent.self).event,
              case .deposited(let amount) = decoded,
              let id = event.streamName.id
        else { return }
        balances[id, default: 0] += amount
    }

    func balance(for id: String) -> Int {
        balances[id, default: 0]
    }
}

@Suite("Integration")
struct IntegrationTests {
    @Test func fullHTTPRequestCycle() async throws {
        // Setup
        let registry = EventTypeRegistry()
        registry.register(BalanceEvent.self, eventTypes: ["Deposited"])
        let store = InMemoryEventStore(registry: registry)
        let pipeline = ProjectionPipeline()
        let balanceProjector = BalanceProjector()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: registry
        )
        services.registerProjector(balanceProjector)

        let repository = AggregateRepository<BalanceAggregate>(
            store: store, registry: registry
        )

        // Build router
        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.addMiddleware {
            ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline)
        }

        router.post("/accounts/{id}/deposit") { request, context -> Response in
            let id = try context.parameters.require("id")
            let deposit = try await request.decode(as: Deposit.self, context: context)
            let requestId = context.requestId

            try await executeAndProject(
                deposit,
                on: id,
                metadata: EventMetadata(traceId: requestId),
                using: DepositHandler.self,
                repository: repository,
                services: services
            )

            return Response(status: .ok)
        }

        router.get("/accounts/{id}/balance") { _, context -> String in
            let id = try context.parameters.require("id")
            let balance = await balanceProjector.balance(for: id)
            return "\(balance)"
        }

        let app = Application(router: router)
        let serviceTask = Task { try await services.run() }

        // Test
        try await app.test(.router) { client in
            // Deposit 100
            let depositBody = try JSONEncoder().encode(Deposit(amount: 100))
            var response = try await client.execute(
                uri: "/accounts/acct-1/deposit",
                method: .post,
                headers: [.contentType: "application/json"],
                body: .init(bytes: depositBody)
            )
            #expect(response.status == .ok)

            // Read balance (flush middleware ensures consistency)
            response = try await client.execute(
                uri: "/accounts/acct-1/balance",
                method: .get
            )
            #expect(String(buffer: response.body) == "100")

            // Deposit 50 more
            let deposit2Body = try JSONEncoder().encode(Deposit(amount: 50))
            response = try await client.execute(
                uri: "/accounts/acct-1/deposit",
                method: .post,
                headers: [.contentType: "application/json"],
                body: .init(bytes: deposit2Body)
            )
            #expect(response.status == .ok)

            // Balance should be 150
            response = try await client.execute(
                uri: "/accounts/acct-1/balance",
                method: .get
            )
            #expect(String(buffer: response.body) == "150")
        }

        serviceTask.cancel()
        try? await serviceTask.value
    }
}
```

**Step 2: Run the test**

Run: `swift test --filter IntegrationTests 2>&1 | tail -10`
Expected: PASS — full end-to-end cycle works.

**Step 3: Commit**

```bash
git add Tests/SongbirdHummingbirdTests/IntegrationTests.swift
git commit -m "Add integration test for full HTTP request cycle"
```

---

## Task 9: Clean Build + Full Test Suite

Verify the entire project builds cleanly and all tests pass.

**Step 1: Build all targets**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with zero warnings.

**Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (previous 211 + new SongbirdHummingbird tests).

**Step 3: Delete the placeholder file**

Remove `Sources/SongbirdHummingbird/SongbirdHummingbird.swift` (placeholder from Task 1, no longer needed since we have real source files).

**Step 4: Verify build still succeeds**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

**Step 5: Final commit**

```bash
git rm Sources/SongbirdHummingbird/SongbirdHummingbird.swift
git commit -m "Remove placeholder file, clean build verified"
```

---

## Summary

| Task | Component | Files |
|------|-----------|-------|
| 1 | Package.swift + module structure | `Package.swift`, placeholder |
| 2 | SongbirdRequestContext | 1 source, 1 test |
| 3 | RequestIdMiddleware | 1 source, 1 test |
| 4 | ProjectionFlushMiddleware | 1 source, 1 test |
| 5 | appendAndProject + SongbirdServices stub | 2 source, 1 test |
| 6 | executeAndProject | modify source, modify test |
| 7 | SongbirdServices full implementation | modify source, 1 test |
| 8 | Integration test | 1 test |
| 9 | Clean build verification | cleanup |
