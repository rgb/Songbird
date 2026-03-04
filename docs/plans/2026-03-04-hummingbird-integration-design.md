# Hummingbird Integration Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

Songbird provides event-sourcing building blocks (event store, aggregates, projections, process managers) but has no integration with an HTTP framework. Users must manually wire middleware, manage service lifecycle, and handle the append-then-enqueue pattern in every route handler.

## Solution

A new `SongbirdHummingbird` module providing building blocks (not a framework) for integrating Songbird with Hummingbird 2: a services container with lifecycle management, a request context with tracing, two middleware components, and route helpers.

## Approach

Building Blocks Only — provide composable primitives. No application builder, no auth middleware, no error mapping. Users compose their own Hummingbird app and wire in Songbird's components however they like.

## Components

### 1. SongbirdServices

A `Sendable` struct that bundles core dependencies and conforms to `Service` (from `swift-service-lifecycle`) for lifecycle management.

```swift
public struct SongbirdServices: Sendable {
    public let eventStore: any EventStore
    public let projectionPipeline: ProjectionPipeline
    public let positionStore: any PositionStore
    public let eventRegistry: EventTypeRegistry
    public let flushProjectionsOnRequest: Bool
}
```

Builder-style registration before starting:

```swift
var services = SongbirdServices(
    eventStore: store,
    projectionPipeline: pipeline,
    positionStore: positionStore,
    eventRegistry: registry,
    flushProjectionsOnRequest: true
)
services.registerProjector(balanceProjector)
services.registerProcessManager(FulfillmentPM.self, tickInterval: .seconds(1))
```

`Service` conformance orchestrates all long-running tasks in a task group:

```swift
extension SongbirdServices: Service {
    public func run() async throws {
        // Starts projection pipeline + all registered process manager runners
        // Handles graceful shutdown via pipeline.stop()
    }
}
```

Usage with Hummingbird:

```swift
let app = Application(router: router)
let serviceGroup = ServiceGroup(
    services: [services, app],
    gracefulShutdownSignals: [.sigterm, .sigint]
)
try await serviceGroup.run()
```

Key decisions:
- Mutable struct (matches Hummingbird's own `Router` pattern)
- `flushProjectionsOnRequest` — `true` in tests, `false` in production
- Doesn't own store/pipeline creation — caller constructs them separately

### 2. SongbirdRequestContext

Minimal extension of Hummingbird's `RequestContext` with request tracing:

```swift
public struct SongbirdRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public var requestId: String?

    public init(source: Source) {
        self.coreContext = .init(source: source)
        self.requestId = nil
    }

    public var requestDecoder: JSONDecoder { JSONDecoder() }
    public var responseEncoder: JSONEncoder { JSONEncoder() }
}
```

Key decisions:
- No `AuthInfo` — users define their own context type or use `hummingbird-auth` when needed
- `requestId` flows into `EventMetadata.traceId` via route helpers
- Users who need auth can define their own `RequestContext` conformance

### 3. RequestIdMiddleware

Typed to `SongbirdRequestContext`. Extracts `X-Request-ID` from the request or generates a UUID, sets it on the context, and echoes it in the response header.

```swift
public struct RequestIdMiddleware: RouterMiddleware {
    public typealias Context = SongbirdRequestContext

    public func handle(
        _ request: Request,
        context: SongbirdRequestContext,
        next: (Request, SongbirdRequestContext) async throws -> Response
    ) async throws -> Response
}
```

### 4. ProjectionFlushMiddleware

Generic over any `RequestContext`. After the route handler completes, waits for the projection pipeline to catch up. Only used in tests.

```swift
public struct ProjectionFlushMiddleware<Context: RequestContext>: RouterMiddleware {
    let pipeline: ProjectionPipeline

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        try? await pipeline.waitForIdle()  // Timeout silently swallowed
        return response
    }
}
```

Key decisions:
- Generic (works with any context type, including custom user contexts)
- Failure silently swallowed — projection timeout shouldn't fail the HTTP request

### 5. Route Helpers

Free functions in `RouteHelpers.swift`:

**`appendAndProject()`** — append a single event + enqueue to pipeline:

```swift
public func appendAndProject(
    _ event: some Event,
    to stream: StreamName,
    metadata: EventMetadata,
    expectedVersion: Int64? = nil,
    services: SongbirdServices
) async throws -> RecordedEvent
```

**`executeAndProject()`** — execute a command via `AggregateRepository` + enqueue all resulting events:

```swift
public func executeAndProject<H: CommandHandler>(
    _ command: H.Cmd,
    on id: String,
    metadata: EventMetadata,
    using handler: H.Type,
    repository: AggregateRepository<H.Agg>,
    services: SongbirdServices
) async throws -> [RecordedEvent]
```

## Package Structure

New module `SongbirdHummingbird`:

```
Sources/SongbirdHummingbird/
    SongbirdServices.swift
    SongbirdRequestContext.swift
    RequestIdMiddleware.swift
    ProjectionFlushMiddleware.swift
    RouteHelpers.swift

Tests/SongbirdHummingbirdTests/
    ...
```

Package.swift additions:
- Dependency: `hummingbird` from `"2.0.0"`
- Target: `SongbirdHummingbird` depends on `Songbird`, `Hummingbird`
- Test target: `SongbirdHummingbirdTests` depends on `SongbirdHummingbird`, `SongbirdTesting`, `HummingbirdTesting`

## Non-Goals

- No auth middleware (just `requestId` on context)
- No `buildApplication()` convenience
- No error-to-HTTP-status mapping
- No security headers middleware
