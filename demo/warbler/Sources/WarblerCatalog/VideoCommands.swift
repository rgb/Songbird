import Songbird

public struct PublishVideo: Command {
    public var commandType: String { "PublishVideo" }
    public let title: String
    public let description: String
    public let creatorId: String

    public init(title: String, description: String, creatorId: String) {
        self.title = title
        self.description = description
        self.creatorId = creatorId
    }
}

public enum PublishVideoHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = PublishVideo

    public static func handle(
        _ command: PublishVideo,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .initial else { throw .alreadyPublished }
        return [.published(title: command.title, description: command.description, creatorId: command.creatorId)]
    }
}

public struct UpdateVideoMetadata: Command {
    public var commandType: String { "UpdateVideoMetadata" }
    public let title: String
    public let description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

public enum UpdateVideoMetadataHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = UpdateVideoMetadata

    public static func handle(
        _ command: UpdateVideoMetadata,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .transcoding || state.status == .published else {
            if state.status == .initial { throw .notPublished }
            throw .videoUnpublished
        }
        return [.metadataUpdated(title: command.title, description: command.description)]
    }
}

public struct CompleteTranscoding: Command {
    public var commandType: String { "CompleteTranscoding" }

    public init() {}
}

public enum CompleteTranscodingHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = CompleteTranscoding

    public static func handle(
        _ command: CompleteTranscoding,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .transcoding else { throw .notTranscoding }
        return [.transcodingCompleted]
    }
}

public struct UnpublishVideo: Command {
    public var commandType: String { "UnpublishVideo" }

    public init() {}
}

public enum UnpublishVideoHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = UnpublishVideo

    public static func handle(
        _ command: UnpublishVideo,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .published || state.status == .transcoding else {
            if state.status == .initial { throw .notPublished }
            throw .videoUnpublished
        }
        return [.unpublished]
    }
}
