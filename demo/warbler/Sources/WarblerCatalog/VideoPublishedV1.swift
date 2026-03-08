import Songbird

/// Version 1 of the VideoPublished event — title and creatorId only, no description.
/// This type exists solely for deserializing old events stored as "VideoPublished_v1".
public struct VideoPublishedV1: Event, Equatable {
    public let title: String
    public let creatorId: String

    public var eventType: String { CatalogEventTypes.videoPublishedV1 }
    public static var version: Int { 1 }

    public init(title: String, creatorId: String) {
        self.title = title
        self.creatorId = creatorId
    }
}

/// Upcasts VideoPublished_v1 → VideoEvent.published (v2) by adding an empty description.
public struct VideoPublishedUpcast: EventUpcast {
    public typealias OldEvent = VideoPublishedV1
    public typealias NewEvent = VideoEvent

    public init() {}

    public func upcast(_ old: VideoPublishedV1) -> VideoEvent {
        .published(title: old.title, description: "", creatorId: old.creatorId)
    }
}
