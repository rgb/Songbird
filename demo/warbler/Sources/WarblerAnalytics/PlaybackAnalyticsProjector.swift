import Foundation
import Songbird
import SongbirdSmew

public actor PlaybackAnalyticsProjector: Projector {
    public let projectorId = "PlaybackAnalytics"
    private let readModel: ReadModelStore

    /// The table name used for tiered storage registration.
    public static let tableName = "video_views"

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    /// Registers the video_views table for tiered storage management.
    /// Call this before `readModel.migrate()`.
    public func registerMigration() async {
        await readModel.registerTable(Self.tableName)
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE video_views (
                    id VARCHAR DEFAULT (uuid()::VARCHAR),
                    video_id VARCHAR NOT NULL,
                    user_id VARCHAR NOT NULL,
                    watched_seconds INTEGER NOT NULL,
                    recorded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case "VideoViewed":
            let envelope = try event.decode(AnalyticsEvent.self)
            guard case .videoViewed(let videoId, let userId, let watchedSeconds) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO video_views (video_id, user_id, watched_seconds, recorded_at) VALUES (\(param: videoId), \(param: userId), \(param: Int64(watchedSeconds)), epoch_ms(\(param: Int64(event.timestamp.timeIntervalSince1970 * 1000))))"
                )
            }

        default:
            break
        }
    }
}
