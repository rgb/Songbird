import Songbird
import SongbirdSmew

public actor VideoCatalogProjector: Projector {
    public let projectorId = "VideoCatalog"
    private let readModel: ReadModelStore

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    public func registerMigration() async {
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE videos (
                    id VARCHAR PRIMARY KEY,
                    title VARCHAR NOT NULL,
                    description VARCHAR NOT NULL DEFAULT '',
                    creator_id VARCHAR NOT NULL,
                    status VARCHAR NOT NULL DEFAULT 'transcoding'
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        guard let videoId = event.streamName.id else { return }

        switch event.eventType {
        case "VideoPublished":
            let envelope = try event.decode(VideoEvent.self)
            guard case .published(let title, let description, let creatorId) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO videos (id, title, description, creator_id, status) VALUES (\(param: videoId), \(param: title), \(param: description), \(param: creatorId), \(param: "transcoding"))"
                )
            }

        case "VideoMetadataUpdated":
            let envelope = try event.decode(VideoEvent.self)
            guard case .metadataUpdated(let title, let description) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE videos SET title = \(param: title), description = \(param: description) WHERE id = \(param: videoId)"
                )
            }

        case "TranscodingCompleted":
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE videos SET status = \(param: "published") WHERE id = \(param: videoId)"
                )
            }

        case "VideoUnpublished":
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE videos SET status = \(param: "unpublished") WHERE id = \(param: videoId)"
                )
            }

        default:
            break
        }
    }
}
