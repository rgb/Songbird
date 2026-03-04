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
