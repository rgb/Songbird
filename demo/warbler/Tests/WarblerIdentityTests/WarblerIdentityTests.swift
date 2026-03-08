import Songbird
import SongbirdTesting
import Testing

@testable import WarblerIdentity

@Suite("UserAggregate")
struct UserAggregateTests {

    @Test func registerUser() throws {
        var harness = TestAggregateHarness<UserAggregate>()
        let events = try harness.when(
            RegisterUser(email: "alice@example.com", displayName: "Alice"),
            using: RegisterUserHandler.self
        )
        #expect(events == [.registered(email: "alice@example.com", displayName: "Alice")])
        #expect(harness.state.isRegistered == true)
        #expect(harness.state.email == "alice@example.com")
        #expect(harness.state.isActive == true)
    }

    @Test func rejectRegistrationWithEmptyEmail() {
        var harness = TestAggregateHarness<UserAggregate>()
        #expect(throws: UserAggregate.Failure.invalidInput("email cannot be empty")) {
            try harness.when(
                RegisterUser(email: "", displayName: "Alice"),
                using: RegisterUserHandler.self
            )
        }
    }

    @Test func rejectDuplicateRegistration() throws {
        var harness = TestAggregateHarness<UserAggregate>()
        harness.given(.registered(email: "alice@example.com", displayName: "Alice"))
        #expect(throws: UserAggregate.Failure.alreadyRegistered) {
            try harness.when(
                RegisterUser(email: "alice@example.com", displayName: "Alice"),
                using: RegisterUserHandler.self
            )
        }
    }

    @Test func updateProfile() throws {
        var harness = TestAggregateHarness<UserAggregate>()
        harness.given(.registered(email: "alice@example.com", displayName: "Alice"))
        let events = try harness.when(
            UpdateProfile(displayName: "Alice B."),
            using: UpdateProfileHandler.self
        )
        #expect(events == [.profileUpdated(displayName: "Alice B.")])
        #expect(harness.state.displayName == "Alice B.")
    }

    @Test func rejectUpdateOnUnregistered() {
        var harness = TestAggregateHarness<UserAggregate>()
        #expect(throws: UserAggregate.Failure.notRegistered) {
            try harness.when(UpdateProfile(displayName: "X"), using: UpdateProfileHandler.self)
        }
    }

    @Test func deactivateUser() throws {
        var harness = TestAggregateHarness<UserAggregate>()
        harness.given(.registered(email: "alice@example.com", displayName: "Alice"))
        let events = try harness.when(DeactivateUser(), using: DeactivateUserHandler.self)
        #expect(events == [.deactivated])
        #expect(harness.state.isActive == false)
    }

    @Test func rejectCommandOnDeactivated() throws {
        var harness = TestAggregateHarness<UserAggregate>()
        harness.given(.registered(email: "alice@example.com", displayName: "Alice"))
        harness.given(.deactivated)
        #expect(throws: UserAggregate.Failure.userDeactivated) {
            try harness.when(UpdateProfile(displayName: "X"), using: UpdateProfileHandler.self)
        }
        #expect(throws: UserAggregate.Failure.userDeactivated) {
            try harness.when(DeactivateUser(), using: DeactivateUserHandler.self)
        }
    }
}
