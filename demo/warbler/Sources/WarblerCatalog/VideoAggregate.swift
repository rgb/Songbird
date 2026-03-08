import Songbird

public enum VideoStatus: String, Sendable, Equatable, Codable {
    case initial
    case transcoding
    case published
    case unpublished
}

public enum VideoAggregate: Aggregate {
    public struct State: Sendable, Equatable, Codable {
        public var status: VideoStatus
        public var title: String?
        public var description: String?
        public var creatorId: String?

        public init() {
            self.status = .initial
            self.title = nil
            self.description = nil
            self.creatorId = nil
        }
    }

    public typealias Event = VideoEvent

    public enum Failure: Error, Equatable {
        case alreadyPublished
        case notPublished
        case notTranscoding
        case videoUnpublished
        case invalidInput(String)
    }

    public static let category = "video"
    public static let initialState = State()

    public static func apply(_ state: State, _ event: VideoEvent) -> State {
        var s = state
        switch event {
        case .published(let title, let description, let creatorId):
            s.status = .transcoding
            s.title = title
            s.description = description
            s.creatorId = creatorId
        case .metadataUpdated(let title, let description):
            s.title = title
            s.description = description
        case .transcodingCompleted:
            s.status = .published
        case .unpublished:
            s.status = .unpublished
        }
        return s
    }
}
