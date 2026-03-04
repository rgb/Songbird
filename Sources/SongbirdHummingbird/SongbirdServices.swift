import Songbird

/// A type that can be run as a long-lived background service.
///
/// Used internally by `SongbirdServices` to type-erase `ProcessManagerRunner<PM>` without
/// capturing generic metatypes in closures (works around a known Swift 6.2 compiler
/// warning for SE-0470 SendableMetatypes, see
/// https://github.com/swiftlang/swift/issues/82116).
private protocol Runnable: Sendable {
    func run() async throws
}

extension ProcessManagerRunner: Runnable {}
extension GatewayRunner: Runnable {}

/// A container for Songbird's core services, providing lifecycle management for the
/// projection pipeline and process manager runners.
///
/// `SongbirdServices` is a mutable struct (matching Hummingbird's `Router` pattern) that
/// you configure before starting the application. Register projectors and process managers,
/// then pass it to a `ServiceGroup` or `Application` (via its `services` parameter).
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
    private var runners: [any Runnable] = []

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
    /// The runner is created eagerly and executes in the task group alongside
    /// the projection pipeline when `run()` is called.
    public mutating func registerProcessManager<PM: ProcessManager>(
        _ type: PM.Type,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        let runner = ProcessManagerRunner<PM>(
            store: eventStore,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
        runners.append(runner)
    }

    /// Registers a gateway to run as a background subscription.
    ///
    /// The runner is created eagerly and executes in the task group alongside
    /// the projection pipeline when `run()` is called.
    public mutating func registerGateway<G: Gateway>(
        _ gateway: G,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        let runner = GatewayRunner(
            gateway: gateway,
            store: eventStore,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
        runners.append(runner)
    }

    // MARK: - Lifecycle

    /// Starts the projection pipeline and all registered process manager runners.
    ///
    /// This method blocks until cancelled. Cancellation propagates to all child tasks:
    /// - The pipeline is stopped via `pipeline.stop()`
    /// - Process manager runners are cancelled (their subscription polling loop exits)
    public func run() async throws {
        for projector in projectors {
            await projectionPipeline.register(projector)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await self.projectionPipeline.run()
                } onCancel: {
                    Task { await self.projectionPipeline.stop() }
                }
            }

            for runner in runners {
                group.addTask {
                    try await runner.run()
                }
            }

            try await group.waitForAll()
        }
    }
}
