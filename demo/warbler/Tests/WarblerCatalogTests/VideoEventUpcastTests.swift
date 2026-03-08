import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import WarblerCatalog

@Suite("VideoEventUpcast")
struct VideoEventUpcastTests {

    @Test func upcastV1ToV2() {
        let v1 = VideoPublishedV1(title: "My Video", creatorId: "creator-1")
        let upcast = VideoPublishedUpcast()
        let v2 = upcast.upcast(v1)
        #expect(v2 == .published(title: "My Video", description: "", creatorId: "creator-1"))
    }

    @Test func registryDecodesV1AsV2() throws {
        let registry = EventTypeRegistry()
        registry.register(VideoEvent.self, eventTypes: [CatalogEventTypes.videoPublished, CatalogEventTypes.videoMetadataUpdated, CatalogEventTypes.videoTranscodingCompleted, CatalogEventTypes.videoUnpublished])
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: CatalogEventTypes.videoPublishedV1
        )

        // Simulate a stored v1 event
        let v1 = VideoPublishedV1(title: "Old Video", creatorId: "c-1")
        let data = try JSONEncoder().encode(v1)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "video", id: "v-1"),
            position: 0,
            globalPosition: 0,
            eventType: CatalogEventTypes.videoPublishedV1,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let videoEvent = decoded as? VideoEvent
        #expect(videoEvent == .published(title: "Old Video", description: "", creatorId: "c-1"))
    }

    @Test func registryDecodesV2Directly() throws {
        let registry = EventTypeRegistry()
        registry.register(VideoEvent.self, eventTypes: [CatalogEventTypes.videoPublished])

        let v2 = VideoEvent.published(title: "New Video", description: "Great content", creatorId: "c-2")
        let data = try JSONEncoder().encode(v2)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "video", id: "v-2"),
            position: 0,
            globalPosition: 0,
            eventType: CatalogEventTypes.videoPublished,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let videoEvent = decoded as? VideoEvent
        #expect(videoEvent == .published(title: "New Video", description: "Great content", creatorId: "c-2"))
    }
}
