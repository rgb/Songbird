import Songbird
import SongbirdTesting
import Testing

@testable import WarblerCatalog

@Suite("VideoAggregate")
struct VideoAggregateTests {

    @Test func publishVideo() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        let events = try harness.when(
            PublishVideo(title: "Swift Tips", description: "Daily tips", creatorId: "creator-1"),
            using: PublishVideoHandler.self
        )
        #expect(events == [.published(title: "Swift Tips", description: "Daily tips", creatorId: "creator-1")])
        #expect(harness.state.status == .transcoding)
        #expect(harness.state.title == "Swift Tips")
    }

    @Test func rejectPublishWithEmptyTitle() {
        var harness = TestAggregateHarness<VideoAggregate>()
        #expect(throws: VideoAggregate.Failure.invalidInput("title cannot be empty")) {
            try harness.when(
                PublishVideo(title: "", description: "A description", creatorId: "creator-1"),
                using: PublishVideoHandler.self
            )
        }
    }

    @Test func rejectPublishWithEmptyDescription() {
        var harness = TestAggregateHarness<VideoAggregate>()
        #expect(throws: VideoAggregate.Failure.invalidInput("description cannot be empty")) {
            try harness.when(
                PublishVideo(title: "A Title", description: "", creatorId: "creator-1"),
                using: PublishVideoHandler.self
            )
        }
    }

    @Test func rejectDuplicatePublish() {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        #expect(throws: VideoAggregate.Failure.alreadyPublished) {
            try harness.when(
                PublishVideo(title: "T2", description: "D2", creatorId: "c"),
                using: PublishVideoHandler.self
            )
        }
    }

    @Test func completeTranscoding() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        let events = try harness.when(CompleteTranscoding(), using: CompleteTranscodingHandler.self)
        #expect(events == [.transcodingCompleted])
        #expect(harness.state.status == .published)
    }

    @Test func rejectTranscodingWhenNotTranscoding() {
        var harness = TestAggregateHarness<VideoAggregate>()
        #expect(throws: VideoAggregate.Failure.notTranscoding) {
            try harness.when(CompleteTranscoding(), using: CompleteTranscodingHandler.self)
        }
    }

    @Test func updateMetadata() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        let events = try harness.when(
            UpdateVideoMetadata(title: "New Title", description: "New Desc"),
            using: UpdateVideoMetadataHandler.self
        )
        #expect(events == [.metadataUpdated(title: "New Title", description: "New Desc")])
        #expect(harness.state.title == "New Title")
        #expect(harness.state.status == .transcoding)
    }

    @Test func unpublishVideoWhileTranscoding() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        // State is .transcoding (published triggers transcoding state)
        let events = try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        #expect(events == [.unpublished])
        #expect(harness.state.status == .unpublished)
    }

    @Test func unpublishVideo() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        harness.given(.transcodingCompleted)
        let events = try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        #expect(events == [.unpublished])
        #expect(harness.state.status == .unpublished)
    }

    @Test func rejectUnpublishWhenInitial() {
        var harness = TestAggregateHarness<VideoAggregate>()
        #expect(throws: VideoAggregate.Failure.notPublished) {
            try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        }
    }

    @Test func rejectMetadataUpdateWhenInitial() {
        var harness = TestAggregateHarness<VideoAggregate>()
        #expect(throws: VideoAggregate.Failure.notPublished) {
            try harness.when(
                UpdateVideoMetadata(title: "T", description: "D"),
                using: UpdateVideoMetadataHandler.self
            )
        }
    }

    @Test func rejectMetadataUpdateWhenUnpublished() {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        harness.given(.transcodingCompleted)
        harness.given(.unpublished)
        #expect(throws: VideoAggregate.Failure.videoUnpublished) {
            try harness.when(
                UpdateVideoMetadata(title: "New", description: "Desc"),
                using: UpdateVideoMetadataHandler.self
            )
        }
    }

    @Test func rejectDoubleUnpublish() {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        harness.given(.transcodingCompleted)
        harness.given(.unpublished)
        #expect(throws: VideoAggregate.Failure.videoUnpublished) {
            try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        }
    }

    @Test func updateMetadataWhenPublished() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        harness.given(.transcodingCompleted)
        let events = try harness.when(
            UpdateVideoMetadata(title: "New Title", description: "New Desc"),
            using: UpdateVideoMetadataHandler.self
        )
        #expect(events == [.metadataUpdated(title: "New Title", description: "New Desc")])
        #expect(harness.state.title == "New Title")
        #expect(harness.state.status == .published)
    }

    @Test func fullLifecycle() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        try harness.when(
            PublishVideo(title: "T", description: "D", creatorId: "c"),
            using: PublishVideoHandler.self
        )
        #expect(harness.state.status == .transcoding)

        try harness.when(CompleteTranscoding(), using: CompleteTranscodingHandler.self)
        #expect(harness.state.status == .published)

        try harness.when(
            UpdateVideoMetadata(title: "Updated", description: "Better"),
            using: UpdateVideoMetadataHandler.self
        )
        #expect(harness.state.status == .published)
        #expect(harness.state.title == "Updated")

        try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        #expect(harness.state.status == .unpublished)
        #expect(harness.appliedEvents.count == 4)
    }
}
