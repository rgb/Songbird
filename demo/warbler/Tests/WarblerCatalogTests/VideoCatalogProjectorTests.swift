import Songbird
import SongbirdSmew
import SongbirdTesting
import Testing

@testable import WarblerCatalog

private struct VideoRow: Decodable, Equatable {
    let id: String
    let title: String
    let description: String
    let creatorId: String
    let status: String
}

@Suite("VideoCatalogProjector")
struct VideoCatalogProjectorTests {

    private func makeProjector() async throws -> (ReadModelStore, VideoCatalogProjector, TestProjectorHarness<VideoCatalogProjector>) {
        let readModel = try ReadModelStore()
        let projector = VideoCatalogProjector(readModel: readModel)
        await projector.registerMigration()
        try await readModel.migrate()
        let harness = TestProjectorHarness(projector: projector)
        return (readModel, projector, harness)
    }

    @Test func projectsVideoPublished() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            VideoEvent.published(title: "Swift Tips", description: "Daily tips", creatorId: "c-1"),
            streamName: StreamName(category: "video", id: "v-1")
        )

        let videos: [VideoRow] = try await readModel.query(VideoRow.self) {
            "SELECT id, title, description, creator_id, status FROM videos"
        }
        #expect(videos.count == 1)
        #expect(videos[0] == VideoRow(id: "v-1", title: "Swift Tips", description: "Daily tips", creatorId: "c-1", status: "transcoding"))
    }

    @Test func projectsFullLifecycle() async throws {
        var (readModel, _, harness) = try await makeProjector()
        let stream = StreamName(category: "video", id: "v-1")

        try await harness.given(VideoEvent.published(title: "T", description: "D", creatorId: "c-1"), streamName: stream)
        try await harness.given(VideoEvent.transcodingCompleted, streamName: stream)
        try await harness.given(VideoEvent.metadataUpdated(title: "Updated", description: "Better"), streamName: stream)

        let video: VideoRow? = try await readModel.queryFirst(VideoRow.self) {
            "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: "v-1")"
        }
        #expect(video?.title == "Updated")
        #expect(video?.description == "Better")
        #expect(video?.status == "published")
    }

    @Test func projectsUnpublish() async throws {
        var (readModel, _, harness) = try await makeProjector()
        let stream = StreamName(category: "video", id: "v-1")

        try await harness.given(VideoEvent.published(title: "T", description: "D", creatorId: "c-1"), streamName: stream)
        try await harness.given(VideoEvent.transcodingCompleted, streamName: stream)
        try await harness.given(VideoEvent.unpublished, streamName: stream)

        let video: VideoRow? = try await readModel.queryFirst(VideoRow.self) {
            "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: "v-1")"
        }
        #expect(video?.status == "unpublished")
    }
}
