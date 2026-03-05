import Songbird

public enum SubscriptionStatus: String, Sendable, Equatable {
    case initial
    case paymentPending
    case active
    case cancelled
}

public enum SubscriptionLifecycleProcess: ProcessManager {
    public struct State: Sendable, Equatable {
        public var status: SubscriptionStatus
        public var userId: String?
        public var plan: String?

        public init() {
            self.status = .initial
            self.userId = nil
            self.plan = nil
        }
    }

    public static let processId = "subscription-lifecycle"
    public static let initialState = State()

    public static let reactions: [AnyReaction<State>] = [
        reaction(for: OnSubscriptionRequested.self, categories: ["subscription"]),
        reaction(for: OnPaymentConfirmed.self, categories: ["subscription"]),
        reaction(for: OnPaymentFailed.self, categories: ["subscription"]),
    ]
}

enum OnSubscriptionRequested: EventReaction {
    typealias PMState = SubscriptionLifecycleProcess.State
    typealias Input = SubscriptionEvent

    static let eventTypes = ["SubscriptionRequested"]

    static func route(_ event: SubscriptionEvent) -> String? {
        switch event {
        case .requested(let subId, _, _): subId
        default: nil
        }
    }

    static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        guard case .requested(_, let userId, let plan) = event else { return state }
        var s = state
        s.status = .paymentPending
        s.userId = userId
        s.plan = plan
        return s
    }

    // No output on request — waiting for payment
}

enum OnPaymentConfirmed: EventReaction {
    typealias PMState = SubscriptionLifecycleProcess.State
    typealias Input = SubscriptionEvent

    static let eventTypes = ["PaymentConfirmed"]

    static func route(_ event: SubscriptionEvent) -> String? {
        switch event {
        case .paymentConfirmed(let subId): subId
        default: nil
        }
    }

    static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        var s = state
        s.status = .active
        return s
    }

    static func react(_ state: PMState, _ event: SubscriptionEvent) -> [any Event] {
        guard let userId = state.userId else { return [] }
        return [SubscriptionLifecycleEvent.accessGranted(userId: userId)]
    }
}

enum OnPaymentFailed: EventReaction {
    typealias PMState = SubscriptionLifecycleProcess.State
    typealias Input = SubscriptionEvent

    static let eventTypes = ["PaymentFailed"]

    static func route(_ event: SubscriptionEvent) -> String? {
        switch event {
        case .paymentFailed(let subId, _): subId
        default: nil
        }
    }

    static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        var s = state
        s.status = .cancelled
        return s
    }

    static func react(_ state: PMState, _ event: SubscriptionEvent) -> [any Event] {
        guard case .paymentFailed(_, let reason) = event else { return [] }
        return [SubscriptionLifecycleEvent.subscriptionCancelled(reason: reason)]
    }
}
