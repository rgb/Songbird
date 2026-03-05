import Songbird
import SongbirdTesting
import Testing

@testable import WarblerSubscriptions

@Suite("SubscriptionLifecycleProcess")
struct SubscriptionProcessTests {

    @Test func requestCreatesPaymentPendingState() throws {
        var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
        try harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )

        let state = harness.state(for: "sub-1")
        #expect(state.status == .paymentPending)
        #expect(state.userId == "user-1")
        #expect(state.plan == "pro")
        #expect(harness.output.isEmpty)
    }

    @Test func paymentConfirmedGrantsAccess() throws {
        var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
        try harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        try harness.given(
            SubscriptionEvent.paymentConfirmed(subscriptionId: "sub-1"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )

        let state = harness.state(for: "sub-1")
        #expect(state.status == .active)
        #expect(harness.output.count == 1)
        let output = harness.output[0] as? SubscriptionLifecycleEvent
        #expect(output == .accessGranted(userId: "user-1"))
    }

    @Test func paymentFailedCancelsSubscription() throws {
        var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
        try harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        try harness.given(
            SubscriptionEvent.paymentFailed(subscriptionId: "sub-1", reason: "Insufficient funds"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )

        let state = harness.state(for: "sub-1")
        #expect(state.status == .cancelled)
        #expect(harness.output.count == 1)
        let output = harness.output[0] as? SubscriptionLifecycleEvent
        #expect(output == .subscriptionCancelled(reason: "Insufficient funds"))
    }

    @Test func isolatesPerEntityState() throws {
        var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
        try harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "u1", plan: "basic"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        try harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-2", userId: "u2", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-2")
        )

        #expect(harness.state(for: "sub-1").plan == "basic")
        #expect(harness.state(for: "sub-2").plan == "pro")
    }
}
