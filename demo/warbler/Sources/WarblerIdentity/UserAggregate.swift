import Songbird

public enum UserAggregate: Aggregate {
    public struct State: Sendable, Equatable, Codable {
        public var isRegistered: Bool
        public var email: String?
        public var displayName: String?
        public var isActive: Bool

        public init() {
            self.isRegistered = false
            self.email = nil
            self.displayName = nil
            self.isActive = false
        }
    }

    public typealias Event = UserEvent

    public enum Failure: Error, Equatable {
        case alreadyRegistered
        case notRegistered
        case userDeactivated
        case invalidInput(String)
    }

    public static let category = "user"
    public static let initialState = State()

    public static func apply(_ state: State, _ event: UserEvent) -> State {
        var s = state
        switch event {
        case .registered(let email, let displayName):
            s.isRegistered = true
            s.email = email
            s.displayName = displayName
            s.isActive = true
        case .profileUpdated(let displayName):
            s.displayName = displayName
        case .deactivated:
            s.isActive = false
        }
        return s
    }
}
