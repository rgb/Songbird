import Songbird

public enum VideoEvent: Event, Equatable {
    case published(title: String, description: String, creatorId: String)
    case metadataUpdated(title: String, description: String)
    case transcodingCompleted
    case unpublished

    public var eventType: String {
        switch self {
        case .published: CatalogEventTypes.videoPublished
        case .metadataUpdated: CatalogEventTypes.videoMetadataUpdated
        case .transcodingCompleted: CatalogEventTypes.videoTranscodingCompleted
        case .unpublished: CatalogEventTypes.videoUnpublished
        }
    }

    /// Version applies to the entire enum. Only `.published` changed from v1 -> v2
    /// (adding `description`). Other cases have always been at this version.
    public static var version: Int { 2 }
}
