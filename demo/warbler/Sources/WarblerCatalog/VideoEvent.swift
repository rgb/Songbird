import Songbird

public enum VideoEvent: Event {
    case published(title: String, description: String, creatorId: String)
    case metadataUpdated(title: String, description: String)
    case transcodingCompleted
    case unpublished

    public var eventType: String {
        switch self {
        case .published: "VideoPublished"
        case .metadataUpdated: "VideoMetadataUpdated"
        case .transcodingCompleted: "TranscodingCompleted"
        case .unpublished: "VideoUnpublished"
        }
    }

    public static var version: Int { 2 }
}
