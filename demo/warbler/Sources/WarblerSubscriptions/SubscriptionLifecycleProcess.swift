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

    public static let processId = "subscriptionLifecycle"
    public static let initialState = State()

    public static let reactions: [AnyReaction<State>] = [
        reaction(for: OnSubscriptionRequested.self, categories: ["subscription"]),
        reaction(for: OnPaymentConfirmed.self, categories: ["subscription"]),
        reaction(for: OnPaymentFailed.self, categories: ["subscription"]),
    ]
}

public enum OnSubscriptionRequested: EventReaction {
    public typealias PMState = SubscriptionLifecycleProcess.State
    public typealias Input = SubscriptionEvent

    public static let eventTypes = [SubscriptionEventTypes.subscriptionRequested]

    public static func route(_ event: SubscriptionEvent) -> String? {
        switch event {
        case .requested(let subId, _, _): subId
        default: nil
        }
    }

    public static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        guard case .requested(_, let userId, let plan) = event else { return state }
        var s = state
        s.status = .paymentPending
        s.userId = userId
        s.plan = plan
        return s
    }

    // No output on request — waiting for payment
}

public enum OnPaymentConfirmed: EventReaction {
    public typealias PMState = SubscriptionLifecycleProcess.State
    public typealias Input = SubscriptionEvent

    public static let eventTypes = [SubscriptionEventTypes.paymentConfirmed]

    public static func route(_ event: SubscriptionEvent) -> String? {
        switch event {
        case .paymentConfirmed(let subId): subId
        default: nil
        }
    }

    public static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        guard state.status == .paymentPending else { return state }
        var s = state
        s.status = .active
        return s
    }

    public static func react(_ state: PMState, _ event: SubscriptionEvent) -> [any Event] {
        guard state.status == .active, let userId = state.userId else { return [] }
        return [SubscriptionLifecycleEvent.accessGranted(userId: userId)]
    }
}

public enum OnPaymentFailed: EventReaction {
    public typealias PMState = SubscriptionLifecycleProcess.State
    public typealias Input = SubscriptionEvent

    public static let eventTypes = [SubscriptionEventTypes.paymentFailed]

    public static func route(_ event: SubscriptionEvent) -> String? {
        switch event {
        case .paymentFailed(let subId, _): subId
        default: nil
        }
    }

    public static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        guard state.status == .paymentPending else { return state }
        var s = state
        s.status = .cancelled
        return s
    }

    public static func react(_ state: PMState, _ event: SubscriptionEvent) -> [any Event] {
        guard state.status == .cancelled, case .paymentFailed(_, let reason) = event, let userId = state.userId else { return [] }
        return [SubscriptionLifecycleEvent.subscriptionCancelled(userId: userId, reason: reason)]
    }
}
