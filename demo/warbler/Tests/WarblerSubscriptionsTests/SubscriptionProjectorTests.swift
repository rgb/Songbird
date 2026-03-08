import Foundation
import Songbird
import SongbirdSmew
import SongbirdTesting
import Testing

@testable import WarblerSubscriptions

private struct SubRow: Decodable, Equatable {
    let id: String
    let userId: String
    let plan: String
    let status: String
}

@Suite("SubscriptionProjector")
struct SubscriptionProjectorTests {

    private func makeProjector() async throws -> (ReadModelStore, SubscriptionProjector, TestProjectorHarness<SubscriptionProjector>) {
        let readModel = try ReadModelStore()
        let projector = SubscriptionProjector(readModel: readModel)
        await projector.registerMigration()
        try await readModel.migrate()
        let harness = TestProjectorHarness(projector: projector)
        return (readModel, projector, harness)
    }

    @Test func projectsSubscriptionRequested() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )

        let subs: [SubRow] = try await readModel.query(SubRow.self) {
            "SELECT id, user_id, plan, status FROM subscriptions"
        }
        #expect(subs.count == 1)
        #expect(subs[0] == SubRow(id: "sub-1", userId: "user-1", plan: "pro", status: "pending"))
    }

    @Test func projectsAccessGranted() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        try await harness.given(
            SubscriptionLifecycleEvent.accessGranted(userId: "user-1"),
            streamName: StreamName(category: "subscriptionLifecycle", id: "sub-1")
        )

        let sub: SubRow? = try await readModel.queryFirst(SubRow.self) {
            "SELECT id, user_id, plan, status FROM subscriptions WHERE id = \(param: "sub-1")"
        }
        #expect(sub?.status == "active")
    }

    @Test func projectsCancellation() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        try await harness.given(
            SubscriptionLifecycleEvent.subscriptionCancelled(userId: "user-1", reason: "Payment failed"),
            streamName: StreamName(category: "subscriptionLifecycle", id: "sub-1")
        )

        let sub: SubRow? = try await readModel.queryFirst(SubRow.self) {
            "SELECT id, user_id, plan, status FROM subscriptions WHERE id = \(param: "sub-1")"
        }
        #expect(sub?.status == "cancelled")
    }

    @Test func ignoresUnknownEventType() async throws {
        let (readModel, projector, _) = try await makeProjector()

        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "subscription", id: "sub-1"),
            position: 0,
            globalPosition: 0,
            eventType: "SomeUnknownEvent",
            data: Data("{}".utf8),
            metadata: EventMetadata(),
            timestamp: Date()
        )
        try await projector.apply(recorded)

        let count = try await readModel.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM subscriptions").scalarInt64()
        }
        #expect(count == 0)
    }
}
