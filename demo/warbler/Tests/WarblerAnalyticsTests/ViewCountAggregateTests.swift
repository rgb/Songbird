import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import WarblerAnalytics

@Suite("ViewCountAggregate")
struct ViewCountAggregateTests {

    @Test func countsViews() {
        var harness = TestAggregateHarness<ViewCountAggregate>()
        harness.given(.viewed(watchedSeconds: 60))
        harness.given(.viewed(watchedSeconds: 120))
        harness.given(.viewed(watchedSeconds: 30))

        #expect(harness.state.totalViews == 3)
        #expect(harness.state.totalWatchedSeconds == 210)
    }

    @Test func startsAtZero() {
        let harness = TestAggregateHarness<ViewCountAggregate>()
        #expect(harness.state == ViewCountAggregate.State())
        #expect(harness.state.totalViews == 0)
        #expect(harness.state.totalWatchedSeconds == 0)
    }

    @Test func stateIsCodableForSnapshots() throws {
        let state = ViewCountAggregate.State(totalViews: 42, totalWatchedSeconds: 3600)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ViewCountAggregate.State.self, from: data)
        #expect(decoded == state)
    }

    @Test func snapshotPolicyEvery100() {
        let policy = SnapshotPolicy.everyNEvents(100)
        #expect(policy == .everyNEvents(100))
    }

    @Test func snapshotRoundTrip() async throws {
        let snapshotStore = InMemorySnapshotStore()
        let stream = StreamName(category: "viewCount", id: "v-1")
        let state = ViewCountAggregate.State(totalViews: 500, totalWatchedSeconds: 25000)

        try await snapshotStore.save(state, version: 499, for: stream)
        let loaded: (state: ViewCountAggregate.State, version: Int64)? = try await snapshotStore.load(for: stream)
        #expect(loaded?.state == state)
        #expect(loaded?.version == 499)
    }
}
