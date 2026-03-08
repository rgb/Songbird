import Songbird
import SongbirdTesting
import Testing

@testable import WarblerAnalytics

@Suite("PlaybackInjector")
struct PlaybackInjectorTests {

    @Test func injectsEventsIntoStream() async throws {
        let injector = PlaybackInjector()

        let viewEvent = AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 60)
        let inbound = InboundEvent(
            event: viewEvent,
            stream: StreamName(category: "analytics", id: "v-1"),
            metadata: EventMetadata(traceId: "test")
        )

        await injector.inject(inbound)

        // Read one event from the async stream
        var iterator = injector.events().makeAsyncIterator()
        let received = await iterator.next()

        #expect(received != nil)
        #expect(received?.stream == StreamName(category: "analytics", id: "v-1"))
        #expect(received?.metadata.traceId == "test")
    }

    @Test func tracksAppendedCount() async throws {
        let injector = PlaybackInjector()

        let inbound = InboundEvent(
            event: AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 30),
            stream: StreamName(category: "analytics", id: "v-1"),
            metadata: EventMetadata()
        )

        let recorded = try RecordedEvent(
            event: AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 30)
        )
        await injector.didAppend(inbound, result: .success(recorded))
        await injector.didAppend(inbound, result: .success(recorded))

        let count = await injector.appendedCount
        #expect(count == 2)
    }

    @Test func doesNotCountFailedAppends() async throws {
        let injector = PlaybackInjector()

        let inbound = InboundEvent(
            event: AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 30),
            stream: StreamName(category: "analytics", id: "v-1"),
            metadata: EventMetadata()
        )

        struct TestError: Error {}
        await injector.didAppend(inbound, result: .failure(TestError()))

        let count = await injector.appendedCount
        #expect(count == 0)
    }
}
