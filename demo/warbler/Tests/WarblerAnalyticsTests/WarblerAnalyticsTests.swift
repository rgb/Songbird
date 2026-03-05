import Songbird
import SongbirdSmew
import SongbirdTesting
import Testing

@testable import WarblerAnalytics

private struct ViewRow: Decodable {
    let videoId: String
    let userId: String
    let watchedSeconds: Int64
}

@Suite("PlaybackAnalyticsProjector")
struct PlaybackAnalyticsProjectorTests {

    private func makeProjector() async throws -> (ReadModelStore, PlaybackAnalyticsProjector, TestProjectorHarness<PlaybackAnalyticsProjector>) {
        let readModel = try ReadModelStore()
        let projector = PlaybackAnalyticsProjector(readModel: readModel)
        await projector.registerMigration()
        try await readModel.migrate()
        let harness = TestProjectorHarness(projector: projector)
        return (readModel, projector, harness)
    }

    @Test func projectsVideoViewed() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 120),
            streamName: StreamName(category: "analytics", id: "v-1")
        )

        let views: [ViewRow] = try await readModel.query(ViewRow.self) {
            "SELECT video_id, user_id, watched_seconds FROM video_views"
        }
        #expect(views.count == 1)
        #expect(views[0].videoId == "v-1")
        #expect(views[0].userId == "u-1")
        #expect(views[0].watchedSeconds == 120)
    }

    @Test func projectsMultipleViews() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 60),
            streamName: StreamName(category: "analytics", id: "v-1")
        )
        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-2", watchedSeconds: 300),
            streamName: StreamName(category: "analytics", id: "v-1")
        )
        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-2", userId: "u-1", watchedSeconds: 45),
            streamName: StreamName(category: "analytics", id: "v-2")
        )

        let count = try await readModel.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM video_views").scalarInt64()
        }
        #expect(count == 3)
    }

    @Test func hasRecordedAtTimestamp() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 60),
            streamName: StreamName(category: "analytics", id: "v-1")
        )

        // Verify recorded_at column exists and has a non-null value
        let hasTimestamp = try await readModel.withConnection { conn in
            try conn.query("SELECT recorded_at FROM video_views WHERE recorded_at IS NOT NULL LIMIT 1").scalarInt64()
        }
        #expect(hasTimestamp != nil)
    }

    @Test func tableIsRegisteredForTiering() async throws {
        let readModel = try ReadModelStore()
        let projector = PlaybackAnalyticsProjector(readModel: readModel)
        await projector.registerMigration()

        let tables = await readModel.registeredTables
        #expect(tables.contains("video_views"))
    }
}
