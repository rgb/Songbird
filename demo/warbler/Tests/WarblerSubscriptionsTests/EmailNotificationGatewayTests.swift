import Songbird
import SongbirdTesting
import Testing

@testable import WarblerSubscriptions

@Suite("EmailNotificationGateway")
struct EmailNotificationGatewayTests {

    @Test func sendsWelcomeOnAccessGranted() async throws {
        let gateway = EmailNotificationGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let event = try RecordedEvent(
            event: SubscriptionLifecycleEvent.accessGranted(userId: "user-1"),
            streamName: StreamName(category: "subscriptionLifecycle", id: "sub-1")
        )
        await harness.given(event)

        #expect(harness.processedEvents.count == 1)
        #expect(harness.errors.isEmpty)

        let notifications = await gateway.sentNotifications
        #expect(notifications.count == 1)
        #expect(notifications[0].type == "welcome")
        #expect(notifications[0].userId == "user-1")
    }

    @Test func sendsCancellationNotification() async throws {
        let gateway = EmailNotificationGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let event = try RecordedEvent(
            event: SubscriptionLifecycleEvent.subscriptionCancelled(userId: "user-1", reason: "Payment failed"),
            streamName: StreamName(category: "subscriptionLifecycle", id: "sub-1")
        )
        await harness.given(event)

        let notifications = await gateway.sentNotifications
        #expect(notifications.count == 1)
        #expect(notifications[0].type == "cancellation")
        #expect(notifications[0].userId == "user-1")
    }

    @Test func ignoresUnrelatedEvents() async throws {
        let gateway = EmailNotificationGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let event = try RecordedEvent(
            event: SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "u1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        await harness.given(event)

        let notifications = await gateway.sentNotifications
        #expect(notifications.isEmpty)
    }
}
