import Songbird

public struct RegisterUser: Command {
    public let commandType = "RegisterUser"
    public let email: String
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case email, displayName
    }

    public init(email: String, displayName: String) {
        self.email = email
        self.displayName = displayName
    }
}

public enum RegisterUserHandler: CommandHandler {
    public typealias Agg = UserAggregate
    public typealias Cmd = RegisterUser

    public static func handle(
        _ command: RegisterUser,
        given state: UserAggregate.State
    ) throws(UserAggregate.Failure) -> [UserEvent] {
        guard !command.email.isEmpty else { throw .invalidInput("email cannot be empty") }
        guard !state.isRegistered else { throw .alreadyRegistered }
        return [.registered(email: command.email, displayName: command.displayName)]
    }
}

public struct UpdateProfile: Command {
    public let commandType = "UpdateProfile"
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case displayName
    }

    public init(displayName: String) {
        self.displayName = displayName
    }
}

public enum UpdateProfileHandler: CommandHandler {
    public typealias Agg = UserAggregate
    public typealias Cmd = UpdateProfile

    public static func handle(
        _ command: UpdateProfile,
        given state: UserAggregate.State
    ) throws(UserAggregate.Failure) -> [UserEvent] {
        guard state.isRegistered else { throw .notRegistered }
        guard state.isActive else { throw .userDeactivated }
        return [.profileUpdated(displayName: command.displayName)]
    }
}

public struct DeactivateUser: Command {
    public let commandType = "DeactivateUser"

    private enum CodingKeys: CodingKey {}

    public init() {}
}

public enum DeactivateUserHandler: CommandHandler {
    public typealias Agg = UserAggregate
    public typealias Cmd = DeactivateUser

    public static func handle(
        _ command: DeactivateUser,
        given state: UserAggregate.State
    ) throws(UserAggregate.Failure) -> [UserEvent] {
        guard state.isRegistered else { throw .notRegistered }
        guard state.isActive else { throw .userDeactivated }
        return [.deactivated]
    }
}
