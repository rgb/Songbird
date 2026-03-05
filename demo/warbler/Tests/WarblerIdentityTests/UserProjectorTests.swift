import Songbird
import SongbirdSmew
import SongbirdTesting
import Testing

@testable import WarblerIdentity

private struct UserRow: Decodable, Equatable {
    let id: String
    let email: String
    let displayName: String
    let isActive: Bool
}

@Suite("UserProjector")
struct UserProjectorTests {

    private func makeProjector() async throws -> (ReadModelStore, UserProjector, TestProjectorHarness<UserProjector>) {
        let readModel = try ReadModelStore()
        let projector = UserProjector(readModel: readModel)
        await projector.registerMigration()
        try await readModel.migrate()
        let harness = TestProjectorHarness(projector: projector)
        return (readModel, projector, harness)
    }

    @Test func projectsUserRegistered() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            UserEvent.registered(email: "alice@example.com", displayName: "Alice"),
            streamName: StreamName(category: "user", id: "user-1")
        )

        let users: [UserRow] = try await readModel.query(UserRow.self) {
            "SELECT id, email, display_name, is_active FROM users"
        }
        #expect(users.count == 1)
        #expect(users[0] == UserRow(id: "user-1", email: "alice@example.com", displayName: "Alice", isActive: true))
    }

    @Test func projectsProfileUpdate() async throws {
        var (readModel, _, harness) = try await makeProjector()
        let stream = StreamName(category: "user", id: "user-1")

        try await harness.given(UserEvent.registered(email: "alice@example.com", displayName: "Alice"), streamName: stream)
        try await harness.given(UserEvent.profileUpdated(displayName: "Alice B."), streamName: stream)

        let user: UserRow? = try await readModel.queryFirst(UserRow.self) {
            "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: "user-1")"
        }
        #expect(user?.displayName == "Alice B.")
    }

    @Test func projectsDeactivation() async throws {
        var (readModel, _, harness) = try await makeProjector()
        let stream = StreamName(category: "user", id: "user-1")

        try await harness.given(UserEvent.registered(email: "alice@example.com", displayName: "Alice"), streamName: stream)
        try await harness.given(UserEvent.deactivated, streamName: stream)

        let user: UserRow? = try await readModel.queryFirst(UserRow.self) {
            "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: "user-1")"
        }
        #expect(user?.isActive == false)
    }

    @Test func ignoresEventsWithoutStreamId() async throws {
        var (readModel, _, harness) = try await makeProjector()

        try await harness.given(
            UserEvent.registered(email: "x", displayName: "x"),
            streamName: StreamName(category: "user")
        )

        let count = try await readModel.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM users").scalarInt64()
        }
        #expect(count == 0)
    }
}
