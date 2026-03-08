import Songbird

public enum UserEvent: Event, Equatable {
    case registered(email: String, displayName: String)
    case profileUpdated(displayName: String)
    case deactivated

    public var eventType: String {
        switch self {
        case .registered: IdentityEventTypes.userRegistered
        case .profileUpdated: IdentityEventTypes.userProfileUpdated
        case .deactivated: IdentityEventTypes.userDeactivated
        }
    }
}
