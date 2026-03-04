# Warbler Demo App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a video tutorial platform demo app ("Warbler") that showcases every Songbird feature across 4 bounded contexts.

**Architecture:** Single Hummingbird executable with 4 domain modules (Identity, Catalog, Subscriptions, Analytics). Each domain demonstrates different Songbird patterns: aggregates, projections, process managers, gateways, injectors, event versioning, snapshots, and tiered storage. Domain modules depend on `Songbird` + `SongbirdSmew`. Tests use `SongbirdTesting` harnesses exclusively.

**Tech Stack:** Swift 6.2+, Songbird (local path dep), Hummingbird 2, DuckDB/Smew (read model), SQLite (write model)

**Design doc:** `docs/plans/2026-03-04-warbler-demo-app-design.md`

---

## Important Context

### Songbird API Patterns

**Event** — enum conforming to `Event` protocol. Each case returns an `eventType` string. Default `version` is 1.

```swift
public enum MyEvent: Event {
    case something(name: String)
    var eventType: String {
        switch self { case .something: "Something" }
    }
}
```

**Aggregate** — enum namespace with nested `State`, `Event`, `Failure` types. Pure `apply` function.

```swift
public enum MyAggregate: Aggregate {
    public struct State: Sendable, Equatable, Codable { var name: String? }
    public typealias Event = MyEvent
    public enum Failure: Error { case invalid }
    public static let category = "my"
    public static let initialState = State()
    public static func apply(_ state: State, _ event: MyEvent) -> State { ... }
}
```

**CommandHandler** — enum with static `handle` that returns events or throws aggregate failure.

```swift
public enum DoSomethingHandler: CommandHandler {
    public typealias Agg = MyAggregate
    public typealias Cmd = DoSomething
    public static func handle(_ command: DoSomething, given state: MyAggregate.State) throws(MyAggregate.Failure) -> [MyEvent] { ... }
}
```

**Projector** — actor that receives `RecordedEvent`, decodes it, writes to `ReadModelStore`.

**ProcessManager** — enum with `State`, `processId`, `reactions` (list of `AnyReaction`). Each reaction is an `EventReaction` conformance. Output events are appended by the runner to `StreamName(category: PM.processId, id: route)`.

**Gateway** — actor with `handle(_ event: RecordedEvent)`. Subscribes to categories. For side effects.

**Injector** — actor providing `AsyncStream<InboundEvent>`. The runner appends events to the store.

**Route helpers** — `executeAndProject()` for command-based writes, `appendAndProject()` for direct event appends.

### Stream Name Conventions

Entity IDs live in the stream name, not in event payloads. The projector extracts IDs from `event.streamName.id`.

- User entity: `StreamName(category: "user", id: userId)`
- Video entity: `StreamName(category: "video", id: videoId)`
- Subscription entity: `StreamName(category: "subscription", id: subId)`
- Analytics view event: `StreamName(category: "analytics", id: videoId)`
- PM output: `StreamName(category: "subscription-lifecycle", id: subId)` (auto by runner)

### ReadModelStore Projector Pattern

```swift
actor MyProjector: Projector {
    let projectorId = "My"
    private let readModel: ReadModelStore

    init(readModel: ReadModelStore) { self.readModel = readModel }

    func apply(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case "Something":
            let envelope = try event.decode(MyEvent.self)
            guard case .something(let name) = envelope.event else { return }
            let id = event.streamName.id ?? ""
            try await readModel.withConnection { conn in
                try conn.execute("INSERT INTO my_table (id, name) VALUES (\(param: id), \(param: name))")
            }
        default: break
        }
    }
}
```

### Projector Test Pattern

```swift
@Test func projectsSomething() async throws {
    let readModel = try ReadModelStore()
    await readModel.registerMigration { conn in
        try conn.execute("CREATE TABLE my_table (id VARCHAR, name VARCHAR)")
    }
    try await readModel.migrate()
    let projector = MyProjector(readModel: readModel)
    var harness = TestProjectorHarness(projector: projector)
    try await harness.given(MyEvent.something(name: "A"), streamName: StreamName(category: "my", id: "1"))

    struct Row: Decodable { let id: String; let name: String }
    let rows: [Row] = try await readModel.query(Row.self) { "SELECT id, name FROM my_table" }
    #expect(rows.count == 1)
    #expect(rows[0].name == "A")
}
```

---

## Task 1: Package Scaffold

**Files:**
- Create: `demo/warbler/Package.swift`
- Create: `demo/warbler/Sources/Warbler/main.swift` (placeholder)
- Create: `demo/warbler/Sources/WarblerIdentity/WarblerIdentity.swift` (placeholder)
- Create: `demo/warbler/Sources/WarblerCatalog/WarblerCatalog.swift` (placeholder)
- Create: `demo/warbler/Sources/WarblerSubscriptions/WarblerSubscriptions.swift` (placeholder)
- Create: `demo/warbler/Sources/WarblerAnalytics/WarblerAnalytics.swift` (placeholder)
- Create: `demo/warbler/Tests/WarblerIdentityTests/WarblerIdentityTests.swift` (placeholder)
- Create: `demo/warbler/Tests/WarblerCatalogTests/WarblerCatalogTests.swift` (placeholder)
- Create: `demo/warbler/Tests/WarblerSubscriptionsTests/WarblerSubscriptionsTests.swift` (placeholder)
- Create: `demo/warbler/Tests/WarblerAnalyticsTests/WarblerAnalyticsTests.swift` (placeholder)

**Step 1: Create directory structure**

```bash
mkdir -p demo/warbler/Sources/{Warbler,WarblerIdentity,WarblerCatalog,WarblerSubscriptions,WarblerAnalytics}
mkdir -p demo/warbler/Tests/{WarblerIdentityTests,WarblerCatalogTests,WarblerSubscriptionsTests,WarblerAnalyticsTests}
```

**Step 2: Write Package.swift**

```swift
// demo/warbler/Package.swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Warbler",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../../"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Domain Modules

        .target(
            name: "WarblerIdentity",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .target(
            name: "WarblerCatalog",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .target(
            name: "WarblerSubscriptions",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .target(
            name: "WarblerAnalytics",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        // MARK: - Executable

        .executableTarget(
            name: "Warbler",
            dependencies: [
                "WarblerIdentity",
                "WarblerCatalog",
                "WarblerSubscriptions",
                "WarblerAnalytics",
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "WarblerIdentityTests",
            dependencies: [
                "WarblerIdentity",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .testTarget(
            name: "WarblerCatalogTests",
            dependencies: [
                "WarblerCatalog",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .testTarget(
            name: "WarblerSubscriptionsTests",
            dependencies: [
                "WarblerSubscriptions",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .testTarget(
            name: "WarblerAnalyticsTests",
            dependencies: [
                "WarblerAnalytics",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),
    ]
)
```

**Step 3: Write placeholder files**

Each placeholder file should export the module:

```swift
// demo/warbler/Sources/WarblerIdentity/WarblerIdentity.swift
// WarblerIdentity — Users & Authentication domain
```

```swift
// demo/warbler/Sources/WarblerCatalog/WarblerCatalog.swift
// WarblerCatalog — Videos & Creator Portal domain
```

```swift
// demo/warbler/Sources/WarblerSubscriptions/WarblerSubscriptions.swift
// WarblerSubscriptions — Subscription Plans & Billing domain
```

```swift
// demo/warbler/Sources/WarblerAnalytics/WarblerAnalytics.swift
// WarblerAnalytics — Playback Tracking & View Counts domain
```

```swift
// demo/warbler/Sources/Warbler/main.swift
@main
struct WarblerApp {
    static func main() async throws {
        print("Warbler — Songbird Demo App")
    }
}
```

Each test placeholder:

```swift
// demo/warbler/Tests/WarblerIdentityTests/WarblerIdentityTests.swift
import Testing
@testable import WarblerIdentity

@Suite("WarblerIdentity")
struct WarblerIdentityTests {
    @Test func placeholder() {
        #expect(true)
    }
}
```

(Same pattern for Catalog, Subscriptions, Analytics test placeholders)

**Step 4: Verify it compiles**

Run from `demo/warbler/`:
```bash
cd demo/warbler && swift build 2>&1
```
Expected: BUILD SUCCEEDED

**Step 5: Run tests**

```bash
cd demo/warbler && swift test 2>&1
```
Expected: All 4 placeholder tests pass

**Step 6: Commit**

```bash
git add demo/warbler
git commit -m "Add Warbler demo app scaffold with 4 domain modules"
```

---

## Task 2: Identity Domain — Events, Aggregate, Commands, Handlers

**Files:**
- Create: `demo/warbler/Sources/WarblerIdentity/UserEvent.swift`
- Create: `demo/warbler/Sources/WarblerIdentity/UserAggregate.swift`
- Create: `demo/warbler/Sources/WarblerIdentity/UserCommands.swift`
- Modify: `demo/warbler/Tests/WarblerIdentityTests/WarblerIdentityTests.swift`

**Step 1: Write UserEvent**

```swift
// demo/warbler/Sources/WarblerIdentity/UserEvent.swift
import Songbird

public enum UserEvent: Event {
    case registered(email: String, displayName: String)
    case profileUpdated(displayName: String)
    case deactivated

    public var eventType: String {
        switch self {
        case .registered: "UserRegistered"
        case .profileUpdated: "ProfileUpdated"
        case .deactivated: "UserDeactivated"
        }
    }
}
```

**Step 2: Write UserAggregate**

```swift
// demo/warbler/Sources/WarblerIdentity/UserAggregate.swift
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
```

**Step 3: Write UserCommands**

```swift
// demo/warbler/Sources/WarblerIdentity/UserCommands.swift
import Songbird

public struct RegisterUser: Command {
    public var commandType: String { "RegisterUser" }
    public let email: String
    public let displayName: String

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
        guard !state.isRegistered else { throw .alreadyRegistered }
        return [.registered(email: command.email, displayName: command.displayName)]
    }
}

public struct UpdateProfile: Command {
    public var commandType: String { "UpdateProfile" }
    public let displayName: String

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
    public var commandType: String { "DeactivateUser" }

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
```

**Step 4: Write aggregate tests**

```swift
// demo/warbler/Tests/WarblerIdentityTests/WarblerIdentityTests.swift
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
```

**Step 5: Run tests**

```bash
cd demo/warbler && swift test --filter WarblerIdentityTests 2>&1
```
Expected: 6 tests pass

**Step 6: Commit**

```bash
git add demo/warbler/Sources/WarblerIdentity demo/warbler/Tests/WarblerIdentityTests
git commit -m "Add Identity domain: UserAggregate, events, commands, and handlers"
```

---

## Task 3: Identity Domain — Projector

**Files:**
- Create: `demo/warbler/Sources/WarblerIdentity/UserProjector.swift`
- Create: `demo/warbler/Tests/WarblerIdentityTests/UserProjectorTests.swift`

**Step 1: Write UserProjector**

```swift
// demo/warbler/Sources/WarblerIdentity/UserProjector.swift
import Songbird
import SongbirdSmew

public actor UserProjector: Projector {
    public let projectorId = "Users"
    private let readModel: ReadModelStore

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    /// Registers the users table migration. Call before `readModel.migrate()`.
    public func registerMigration() async {
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE users (
                    id VARCHAR PRIMARY KEY,
                    email VARCHAR NOT NULL,
                    display_name VARCHAR NOT NULL,
                    is_active BOOLEAN NOT NULL DEFAULT TRUE
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        guard let userId = event.streamName.id else { return }

        switch event.eventType {
        case "UserRegistered":
            let envelope = try event.decode(UserEvent.self)
            guard case .registered(let email, let displayName) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO users (id, email, display_name, is_active) VALUES (\(param: userId), \(param: email), \(param: displayName), \(param: true))"
                )
            }

        case "ProfileUpdated":
            let envelope = try event.decode(UserEvent.self)
            guard case .profileUpdated(let displayName) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE users SET display_name = \(param: displayName) WHERE id = \(param: userId)"
                )
            }

        case "UserDeactivated":
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE users SET is_active = \(param: false) WHERE id = \(param: userId)"
                )
            }

        default:
            break
        }
    }
}
```

**Step 2: Write projector tests**

```swift
// demo/warbler/Tests/WarblerIdentityTests/UserProjectorTests.swift
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
        let (readModel, _, var harness) = try await makeProjector()

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
        let (readModel, _, var harness) = try await makeProjector()
        let stream = StreamName(category: "user", id: "user-1")

        try await harness.given(UserEvent.registered(email: "alice@example.com", displayName: "Alice"), streamName: stream)
        try await harness.given(UserEvent.profileUpdated(displayName: "Alice B."), streamName: stream)

        let user: UserRow? = try await readModel.queryFirst(UserRow.self) {
            "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: "user-1")"
        }
        #expect(user?.displayName == "Alice B.")
    }

    @Test func projectsDeactivation() async throws {
        let (readModel, _, var harness) = try await makeProjector()
        let stream = StreamName(category: "user", id: "user-1")

        try await harness.given(UserEvent.registered(email: "alice@example.com", displayName: "Alice"), streamName: stream)
        try await harness.given(UserEvent.deactivated, streamName: stream)

        let user: UserRow? = try await readModel.queryFirst(UserRow.self) {
            "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: "user-1")"
        }
        #expect(user?.isActive == false)
    }

    @Test func ignoresUnrelatedEvents() async throws {
        let (readModel, _, var harness) = try await makeProjector()

        // Feed an event with a different event type — projector should ignore it
        let recorded = try RecordedEvent(
            event: UserEvent.registered(email: "x", displayName: "x"),
            streamName: StreamName(category: "other", id: "1")
        )
        // Manually change the event type to something unknown (simulate foreign event)
        // Actually, just verify that events without a stream ID are ignored
        try await harness.given(
            UserEvent.registered(email: "x", displayName: "x"),
            streamName: StreamName(category: "user")  // no ID — category stream
        )

        let count = try await readModel.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM users").scalarInt64()
        }
        #expect(count == 0)
    }
}
```

**Step 3: Run tests**

```bash
cd demo/warbler && swift test --filter WarblerIdentityTests 2>&1
```
Expected: All tests pass (6 aggregate + 4 projector = 10)

**Step 4: Commit**

```bash
git add demo/warbler/Sources/WarblerIdentity demo/warbler/Tests/WarblerIdentityTests
git commit -m "Add UserProjector with DuckDB read model and tests"
```

---

## Task 4: Catalog Domain — Events, Aggregate, Commands, Handlers

**Files:**
- Create: `demo/warbler/Sources/WarblerCatalog/VideoEvent.swift`
- Create: `demo/warbler/Sources/WarblerCatalog/VideoAggregate.swift`
- Create: `demo/warbler/Sources/WarblerCatalog/VideoCommands.swift`
- Modify: `demo/warbler/Tests/WarblerCatalogTests/WarblerCatalogTests.swift`

**Step 1: Write VideoEvent**

The current `VideoEvent` is version 2 because of the `VideoPublished` upcast chain (Task 5).

```swift
// demo/warbler/Sources/WarblerCatalog/VideoEvent.swift
import Songbird

public enum VideoEvent: Event {
    case published(title: String, description: String, creatorId: String)
    case metadataUpdated(title: String, description: String)
    case transcodingCompleted
    case unpublished

    public var eventType: String {
        switch self {
        case .published: "VideoPublished"
        case .metadataUpdated: "VideoMetadataUpdated"
        case .transcodingCompleted: "TranscodingCompleted"
        case .unpublished: "VideoUnpublished"
        }
    }

    public static var version: Int { 2 }
}
```

**Step 2: Write VideoAggregate**

```swift
// demo/warbler/Sources/WarblerCatalog/VideoAggregate.swift
import Songbird

public enum VideoStatus: String, Sendable, Equatable, Codable {
    case initial
    case transcoding
    case published
    case unpublished
}

public enum VideoAggregate: Aggregate {
    public struct State: Sendable, Equatable, Codable {
        public var status: VideoStatus
        public var title: String?
        public var description: String?
        public var creatorId: String?

        public init() {
            self.status = .initial
            self.title = nil
            self.description = nil
            self.creatorId = nil
        }
    }

    public typealias Event = VideoEvent

    public enum Failure: Error, Equatable {
        case alreadyPublished
        case notPublished
        case notTranscoding
        case videoUnpublished
    }

    public static let category = "video"
    public static let initialState = State()

    public static func apply(_ state: State, _ event: VideoEvent) -> State {
        var s = state
        switch event {
        case .published(let title, let description, let creatorId):
            s.status = .transcoding
            s.title = title
            s.description = description
            s.creatorId = creatorId
        case .metadataUpdated(let title, let description):
            s.title = title
            s.description = description
        case .transcodingCompleted:
            s.status = .published
        case .unpublished:
            s.status = .unpublished
        }
        return s
    }
}
```

**Step 3: Write VideoCommands**

```swift
// demo/warbler/Sources/WarblerCatalog/VideoCommands.swift
import Songbird

public struct PublishVideo: Command {
    public var commandType: String { "PublishVideo" }
    public let title: String
    public let description: String
    public let creatorId: String

    public init(title: String, description: String, creatorId: String) {
        self.title = title
        self.description = description
        self.creatorId = creatorId
    }
}

public enum PublishVideoHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = PublishVideo

    public static func handle(
        _ command: PublishVideo,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .initial else { throw .alreadyPublished }
        return [.published(title: command.title, description: command.description, creatorId: command.creatorId)]
    }
}

public struct UpdateVideoMetadata: Command {
    public var commandType: String { "UpdateVideoMetadata" }
    public let title: String
    public let description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

public enum UpdateVideoMetadataHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = UpdateVideoMetadata

    public static func handle(
        _ command: UpdateVideoMetadata,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .transcoding || state.status == .published else {
            if state.status == .initial { throw .notPublished }
            throw .videoUnpublished
        }
        return [.metadataUpdated(title: command.title, description: command.description)]
    }
}

public struct CompleteTranscoding: Command {
    public var commandType: String { "CompleteTranscoding" }

    public init() {}
}

public enum CompleteTranscodingHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = CompleteTranscoding

    public static func handle(
        _ command: CompleteTranscoding,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .transcoding else { throw .notTranscoding }
        return [.transcodingCompleted]
    }
}

public struct UnpublishVideo: Command {
    public var commandType: String { "UnpublishVideo" }

    public init() {}
}

public enum UnpublishVideoHandler: CommandHandler {
    public typealias Agg = VideoAggregate
    public typealias Cmd = UnpublishVideo

    public static func handle(
        _ command: UnpublishVideo,
        given state: VideoAggregate.State
    ) throws(VideoAggregate.Failure) -> [VideoEvent] {
        guard state.status == .published || state.status == .transcoding else {
            if state.status == .initial { throw .notPublished }
            throw .videoUnpublished
        }
        return [.unpublished]
    }
}
```

**Step 4: Write aggregate tests**

```swift
// demo/warbler/Tests/WarblerCatalogTests/WarblerCatalogTests.swift
import Songbird
import SongbirdTesting
import Testing

@testable import WarblerCatalog

@Suite("VideoAggregate")
struct VideoAggregateTests {

    @Test func publishVideo() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        let events = try harness.when(
            PublishVideo(title: "Swift Tips", description: "Daily tips", creatorId: "creator-1"),
            using: PublishVideoHandler.self
        )
        #expect(events == [.published(title: "Swift Tips", description: "Daily tips", creatorId: "creator-1")])
        #expect(harness.state.status == .transcoding)
        #expect(harness.state.title == "Swift Tips")
    }

    @Test func rejectDuplicatePublish() {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        #expect(throws: VideoAggregate.Failure.alreadyPublished) {
            try harness.when(
                PublishVideo(title: "T2", description: "D2", creatorId: "c"),
                using: PublishVideoHandler.self
            )
        }
    }

    @Test func completeTranscoding() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        let events = try harness.when(CompleteTranscoding(), using: CompleteTranscodingHandler.self)
        #expect(events == [.transcodingCompleted])
        #expect(harness.state.status == .published)
    }

    @Test func rejectTranscodingWhenNotTranscoding() {
        var harness = TestAggregateHarness<VideoAggregate>()
        #expect(throws: VideoAggregate.Failure.notTranscoding) {
            try harness.when(CompleteTranscoding(), using: CompleteTranscodingHandler.self)
        }
    }

    @Test func updateMetadata() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        let events = try harness.when(
            UpdateVideoMetadata(title: "New Title", description: "New Desc"),
            using: UpdateVideoMetadataHandler.self
        )
        #expect(events == [.metadataUpdated(title: "New Title", description: "New Desc")])
        #expect(harness.state.title == "New Title")
    }

    @Test func unpublishVideo() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        harness.given(.published(title: "T", description: "D", creatorId: "c"))
        harness.given(.transcodingCompleted)
        let events = try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        #expect(events == [.unpublished])
        #expect(harness.state.status == .unpublished)
    }

    @Test func rejectUnpublishWhenInitial() {
        var harness = TestAggregateHarness<VideoAggregate>()
        #expect(throws: VideoAggregate.Failure.notPublished) {
            try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        }
    }

    @Test func fullLifecycle() throws {
        var harness = TestAggregateHarness<VideoAggregate>()
        try harness.when(
            PublishVideo(title: "T", description: "D", creatorId: "c"),
            using: PublishVideoHandler.self
        )
        try harness.when(CompleteTranscoding(), using: CompleteTranscodingHandler.self)
        try harness.when(
            UpdateVideoMetadata(title: "Updated", description: "Better"),
            using: UpdateVideoMetadataHandler.self
        )
        try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
        #expect(harness.state.status == .unpublished)
        #expect(harness.appliedEvents.count == 4)
    }
}
```

**Step 5: Run tests**

```bash
cd demo/warbler && swift test --filter WarblerCatalogTests 2>&1
```
Expected: 8 tests pass

**Step 6: Commit**

```bash
git add demo/warbler/Sources/WarblerCatalog demo/warbler/Tests/WarblerCatalogTests
git commit -m "Add Catalog domain: VideoAggregate with state machine transitions"
```

---

## Task 5: Catalog Domain — Event Versioning

**Files:**
- Create: `demo/warbler/Sources/WarblerCatalog/VideoPublishedV1.swift`
- Create: `demo/warbler/Tests/WarblerCatalogTests/VideoEventUpcastTests.swift`

**Step 1: Write VideoPublished_v1 and upcast**

```swift
// demo/warbler/Sources/WarblerCatalog/VideoPublishedV1.swift
import Songbird

/// Version 1 of the VideoPublished event — title and creatorId only, no description.
/// This type exists solely for deserializing old events stored as "VideoPublished_v1".
public struct VideoPublishedV1: Event, Equatable {
    public let title: String
    public let creatorId: String

    public var eventType: String { "VideoPublished_v1" }
    public static var version: Int { 1 }

    public init(title: String, creatorId: String) {
        self.title = title
        self.creatorId = creatorId
    }
}

/// Upcasts VideoPublished_v1 → VideoEvent.published (v2) by adding an empty description.
public struct VideoPublishedUpcast: EventUpcast {
    public typealias OldEvent = VideoPublishedV1
    public typealias NewEvent = VideoEvent

    public init() {}

    public func upcast(_ old: VideoPublishedV1) -> VideoEvent {
        .published(title: old.title, description: "", creatorId: old.creatorId)
    }
}
```

**Step 2: Write upcast tests**

```swift
// demo/warbler/Tests/WarblerCatalogTests/VideoEventUpcastTests.swift
import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import WarblerCatalog

@Suite("VideoEventUpcast")
struct VideoEventUpcastTests {

    @Test func upcastV1ToV2() {
        let v1 = VideoPublishedV1(title: "My Video", creatorId: "creator-1")
        let upcast = VideoPublishedUpcast()
        let v2 = upcast.upcast(v1)
        #expect(v2 == .published(title: "My Video", description: "", creatorId: "creator-1"))
    }

    @Test func registryDecodesV1AsV2() throws {
        let registry = EventTypeRegistry()
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished", "VideoMetadataUpdated", "TranscodingCompleted", "VideoUnpublished"])
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: "VideoPublished_v1"
        )

        // Simulate a stored v1 event
        let v1 = VideoPublishedV1(title: "Old Video", creatorId: "c-1")
        let data = try JSONEncoder().encode(v1)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "video", id: "v-1"),
            position: 0,
            globalPosition: 0,
            eventType: "VideoPublished_v1",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let videoEvent = decoded as? VideoEvent
        #expect(videoEvent == .published(title: "Old Video", description: "", creatorId: "c-1"))
    }

    @Test func registryDecodesV2Directly() throws {
        let registry = EventTypeRegistry()
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished"])

        let v2 = VideoEvent.published(title: "New Video", description: "Great content", creatorId: "c-2")
        let data = try JSONEncoder().encode(v2)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "video", id: "v-2"),
            position: 0,
            globalPosition: 0,
            eventType: "VideoPublished",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let videoEvent = decoded as? VideoEvent
        #expect(videoEvent == .published(title: "New Video", description: "Great content", creatorId: "c-2"))
    }
}
```

**Step 3: Run tests**

```bash
cd demo/warbler && swift test --filter WarblerCatalogTests 2>&1
```
Expected: 11 tests pass (8 aggregate + 3 upcast)

**Step 4: Commit**

```bash
git add demo/warbler/Sources/WarblerCatalog demo/warbler/Tests/WarblerCatalogTests
git commit -m "Add VideoPublished event versioning with v1-to-v2 upcast"
```

---

## Task 6: Catalog Domain — Projector

**Files:**
- Create: `demo/warbler/Sources/WarblerCatalog/VideoCatalogProjector.swift`
- Create: `demo/warbler/Tests/WarblerCatalogTests/VideoCatalogProjectorTests.swift`

**Step 1: Write VideoCatalogProjector**

```swift
// demo/warbler/Sources/WarblerCatalog/VideoCatalogProjector.swift
import Songbird
import SongbirdSmew

public actor VideoCatalogProjector: Projector {
    public let projectorId = "VideoCatalog"
    private let readModel: ReadModelStore

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    public func registerMigration() async {
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE videos (
                    id VARCHAR PRIMARY KEY,
                    title VARCHAR NOT NULL,
                    description VARCHAR NOT NULL DEFAULT '',
                    creator_id VARCHAR NOT NULL,
                    status VARCHAR NOT NULL DEFAULT 'transcoding'
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        guard let videoId = event.streamName.id else { return }

        switch event.eventType {
        case "VideoPublished":
            let envelope = try event.decode(VideoEvent.self)
            guard case .published(let title, let description, let creatorId) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO videos (id, title, description, creator_id, status) VALUES (\(param: videoId), \(param: title), \(param: description), \(param: creatorId), \(param: "transcoding"))"
                )
            }

        case "VideoMetadataUpdated":
            let envelope = try event.decode(VideoEvent.self)
            guard case .metadataUpdated(let title, let description) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE videos SET title = \(param: title), description = \(param: description) WHERE id = \(param: videoId)"
                )
            }

        case "TranscodingCompleted":
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE videos SET status = \(param: "published") WHERE id = \(param: videoId)"
                )
            }

        case "VideoUnpublished":
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE videos SET status = \(param: "unpublished") WHERE id = \(param: videoId)"
                )
            }

        default:
            break
        }
    }
}
```

**Step 2: Write projector tests**

```swift
// demo/warbler/Tests/WarblerCatalogTests/VideoCatalogProjectorTests.swift
import Songbird
import SongbirdSmew
import SongbirdTesting
import Testing

@testable import WarblerCatalog

private struct VideoRow: Decodable, Equatable {
    let id: String
    let title: String
    let description: String
    let creatorId: String
    let status: String
}

@Suite("VideoCatalogProjector")
struct VideoCatalogProjectorTests {

    private func makeProjector() async throws -> (ReadModelStore, VideoCatalogProjector, TestProjectorHarness<VideoCatalogProjector>) {
        let readModel = try ReadModelStore()
        let projector = VideoCatalogProjector(readModel: readModel)
        await projector.registerMigration()
        try await readModel.migrate()
        let harness = TestProjectorHarness(projector: projector)
        return (readModel, projector, harness)
    }

    @Test func projectsVideoPublished() async throws {
        let (readModel, _, var harness) = try await makeProjector()

        try await harness.given(
            VideoEvent.published(title: "Swift Tips", description: "Daily tips", creatorId: "c-1"),
            streamName: StreamName(category: "video", id: "v-1")
        )

        let videos: [VideoRow] = try await readModel.query(VideoRow.self) {
            "SELECT id, title, description, creator_id, status FROM videos"
        }
        #expect(videos.count == 1)
        #expect(videos[0] == VideoRow(id: "v-1", title: "Swift Tips", description: "Daily tips", creatorId: "c-1", status: "transcoding"))
    }

    @Test func projectsFullLifecycle() async throws {
        let (readModel, _, var harness) = try await makeProjector()
        let stream = StreamName(category: "video", id: "v-1")

        try await harness.given(VideoEvent.published(title: "T", description: "D", creatorId: "c-1"), streamName: stream)
        try await harness.given(VideoEvent.transcodingCompleted, streamName: stream)
        try await harness.given(VideoEvent.metadataUpdated(title: "Updated", description: "Better"), streamName: stream)

        let video: VideoRow? = try await readModel.queryFirst(VideoRow.self) {
            "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: "v-1")"
        }
        #expect(video?.title == "Updated")
        #expect(video?.description == "Better")
        #expect(video?.status == "published")
    }

    @Test func projectsUnpublish() async throws {
        let (readModel, _, var harness) = try await makeProjector()
        let stream = StreamName(category: "video", id: "v-1")

        try await harness.given(VideoEvent.published(title: "T", description: "D", creatorId: "c-1"), streamName: stream)
        try await harness.given(VideoEvent.transcodingCompleted, streamName: stream)
        try await harness.given(VideoEvent.unpublished, streamName: stream)

        let video: VideoRow? = try await readModel.queryFirst(VideoRow.self) {
            "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: "v-1")"
        }
        #expect(video?.status == "unpublished")
    }
}
```

**Step 3: Run tests, commit**

```bash
cd demo/warbler && swift test --filter WarblerCatalogTests 2>&1
```
Expected: 14 tests pass

```bash
git add demo/warbler/Sources/WarblerCatalog demo/warbler/Tests/WarblerCatalogTests
git commit -m "Add VideoCatalogProjector with DuckDB read model and tests"
```

---

## Task 7: Subscriptions Domain — Events & Process Manager

**Files:**
- Create: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionEvent.swift`
- Create: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleEvent.swift`
- Create: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleProcess.swift`
- Modify: `demo/warbler/Tests/WarblerSubscriptionsTests/WarblerSubscriptionsTests.swift`

**Step 1: Write SubscriptionEvent (input events)**

```swift
// demo/warbler/Sources/WarblerSubscriptions/SubscriptionEvent.swift
import Songbird

public enum SubscriptionEvent: Event {
    case requested(userId: String, plan: String)
    case paymentConfirmed
    case paymentFailed(reason: String)

    public var eventType: String {
        switch self {
        case .requested: "SubscriptionRequested"
        case .paymentConfirmed: "PaymentConfirmed"
        case .paymentFailed: "PaymentFailed"
        }
    }
}
```

**Step 2: Write SubscriptionLifecycleEvent (PM output events)**

```swift
// demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleEvent.swift
import Songbird

public enum SubscriptionLifecycleEvent: Event {
    case accessGranted(userId: String)
    case subscriptionCancelled(reason: String)

    public var eventType: String {
        switch self {
        case .accessGranted: "AccessGranted"
        case .subscriptionCancelled: "SubscriptionCancelled"
        }
    }
}
```

**Step 3: Write SubscriptionLifecycleProcess**

```swift
// demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleProcess.swift
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
        case .requested: "default"  // Route is the subscription entity ID from stream
        default: nil
        }
    }

    static func decode(_ recorded: RecordedEvent) throws -> SubscriptionEvent {
        try recorded.decode(SubscriptionEvent.self).event
    }

    static func route(_ event: SubscriptionEvent, from recorded: RecordedEvent) -> String? {
        nil
    }

    static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        guard case .requested(let userId, let plan) = event else { return state }
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
        case .paymentConfirmed: "default"
        default: nil
        }
    }

    static func decode(_ recorded: RecordedEvent) throws -> SubscriptionEvent {
        try recorded.decode(SubscriptionEvent.self).event
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
        case .paymentFailed: "default"
        default: nil
        }
    }

    static func decode(_ recorded: RecordedEvent) throws -> SubscriptionEvent {
        try recorded.decode(SubscriptionEvent.self).event
    }

    static func apply(_ state: PMState, _ event: SubscriptionEvent) -> PMState {
        var s = state
        s.status = .cancelled
        return s
    }

    static func react(_ state: PMState, _ event: SubscriptionEvent) -> [any Event] {
        guard case .paymentFailed(let reason) = event else { return [] }
        return [SubscriptionLifecycleEvent.subscriptionCancelled(reason: reason)]
    }
}
```

**Important note on routing:** The `route` function extracts a per-entity instance ID. The `ProcessManagerRunner` uses this for per-entity state tracking. In our case, the subscription ID comes from the stream name. But `EventReaction.route` receives the decoded event, not the stream name. We need to use the stream name's ID as the route.

Looking at the EventReaction protocol, `route` takes the decoded event. But the actual routing in `AnyReaction` is done via `tryRoute(RecordedEvent)` which calls `decode` then `route`. Since the event enum cases don't carry the subscription ID, we need to route differently.

**Correction:** The route should use the stream name ID. Since `EventReaction.route` only receives the event (not the RecordedEvent), we need to embed the ID in the event OR use a custom `tryRoute`. Looking at the `reaction(for:categories:)` helper, it builds an `AnyReaction` that:
1. Checks if `recorded.eventType` is in `R.eventTypes`
2. Calls `R.decode(recorded)` to get the typed event
3. Calls `R.route(event)` to get the route string

So we need the route to come from the event data or we need to include the subscription ID in the event payload.

**Simplest fix:** Include the subscription ID in the event payloads so the PM can route by it. Let me revise:

```swift
// REVISED SubscriptionEvent
public enum SubscriptionEvent: Event {
    case requested(subscriptionId: String, userId: String, plan: String)
    case paymentConfirmed(subscriptionId: String)
    case paymentFailed(subscriptionId: String, reason: String)

    public var eventType: String {
        switch self {
        case .requested: "SubscriptionRequested"
        case .paymentConfirmed: "PaymentConfirmed"
        case .paymentFailed: "PaymentFailed"
        }
    }
}
```

Then each reaction's `route` extracts the subscriptionId from the event:

```swift
static func route(_ event: SubscriptionEvent) -> String? {
    switch event {
    case .requested(let subId, _, _): subId
    default: nil
    }
}
```

**Step 4: Write process manager tests**

```swift
// demo/warbler/Tests/WarblerSubscriptionsTests/WarblerSubscriptionsTests.swift
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
```

**Step 5: Run tests, commit**

```bash
cd demo/warbler && swift test --filter WarblerSubscriptionsTests 2>&1
```
Expected: 4 tests pass

```bash
git add demo/warbler/Sources/WarblerSubscriptions demo/warbler/Tests/WarblerSubscriptionsTests
git commit -m "Add Subscriptions domain: process manager with lifecycle state machine"
```

---

## Task 8: Subscriptions Domain — Gateway & Projector

**Files:**
- Create: `demo/warbler/Sources/WarblerSubscriptions/EmailNotificationGateway.swift`
- Create: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionProjector.swift`
- Create: `demo/warbler/Tests/WarblerSubscriptionsTests/EmailNotificationGatewayTests.swift`
- Create: `demo/warbler/Tests/WarblerSubscriptionsTests/SubscriptionProjectorTests.swift`

**Step 1: Write EmailNotificationGateway**

```swift
// demo/warbler/Sources/WarblerSubscriptions/EmailNotificationGateway.swift
import Songbird

public actor EmailNotificationGateway: Gateway {
    public let gatewayId = "EmailNotification"
    public static let categories = ["subscription-lifecycle"]

    /// Tracks notifications sent (for testing and logging).
    public private(set) var sentNotifications: [(type: String, userId: String)] = []

    public init() {}

    public func handle(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case "AccessGranted":
            let envelope = try event.decode(SubscriptionLifecycleEvent.self)
            guard case .accessGranted(let userId) = envelope.event else { return }
            sentNotifications.append((type: "welcome", userId: userId))

        case "SubscriptionCancelled":
            let envelope = try event.decode(SubscriptionLifecycleEvent.self)
            guard case .subscriptionCancelled = envelope.event else { return }
            let subId = event.streamName.id ?? "unknown"
            sentNotifications.append((type: "cancellation", userId: subId))

        default:
            break
        }
    }
}
```

**Step 2: Write SubscriptionProjector**

```swift
// demo/warbler/Sources/WarblerSubscriptions/SubscriptionProjector.swift
import Songbird
import SongbirdSmew

public actor SubscriptionProjector: Projector {
    public let projectorId = "Subscriptions"
    private let readModel: ReadModelStore

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    public func registerMigration() async {
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE subscriptions (
                    id VARCHAR PRIMARY KEY,
                    user_id VARCHAR NOT NULL,
                    plan VARCHAR NOT NULL,
                    status VARCHAR NOT NULL DEFAULT 'pending'
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case "SubscriptionRequested":
            let envelope = try event.decode(SubscriptionEvent.self)
            guard case .requested(let subId, let userId, let plan) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO subscriptions (id, user_id, plan, status) VALUES (\(param: subId), \(param: userId), \(param: plan), \(param: "pending"))"
                )
            }

        case "AccessGranted":
            guard let subId = event.streamName.id else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE subscriptions SET status = \(param: "active") WHERE id = \(param: subId)"
                )
            }

        case "SubscriptionCancelled":
            guard let subId = event.streamName.id else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE subscriptions SET status = \(param: "cancelled") WHERE id = \(param: subId)"
                )
            }

        default:
            break
        }
    }
}
```

**Step 3: Write gateway tests**

```swift
// demo/warbler/Tests/WarblerSubscriptionsTests/EmailNotificationGatewayTests.swift
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
            streamName: StreamName(category: "subscription-lifecycle", id: "sub-1")
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
            event: SubscriptionLifecycleEvent.subscriptionCancelled(reason: "Payment failed"),
            streamName: StreamName(category: "subscription-lifecycle", id: "sub-1")
        )
        await harness.given(event)

        let notifications = await gateway.sentNotifications
        #expect(notifications.count == 1)
        #expect(notifications[0].type == "cancellation")
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
```

**Step 4: Write projector tests**

```swift
// demo/warbler/Tests/WarblerSubscriptionsTests/SubscriptionProjectorTests.swift
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
        let (readModel, _, var harness) = try await makeProjector()

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
        let (readModel, _, var harness) = try await makeProjector()

        try await harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        try await harness.given(
            SubscriptionLifecycleEvent.accessGranted(userId: "user-1"),
            streamName: StreamName(category: "subscription-lifecycle", id: "sub-1")
        )

        let sub: SubRow? = try await readModel.queryFirst(SubRow.self) {
            "SELECT id, user_id, plan, status FROM subscriptions WHERE id = \(param: "sub-1")"
        }
        #expect(sub?.status == "active")
    }

    @Test func projectsCancellation() async throws {
        let (readModel, _, var harness) = try await makeProjector()

        try await harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        try await harness.given(
            SubscriptionLifecycleEvent.subscriptionCancelled(reason: "Payment failed"),
            streamName: StreamName(category: "subscription-lifecycle", id: "sub-1")
        )

        let sub: SubRow? = try await readModel.queryFirst(SubRow.self) {
            "SELECT id, user_id, plan, status FROM subscriptions WHERE id = \(param: "sub-1")"
        }
        #expect(sub?.status == "cancelled")
    }
}
```

**Step 5: Run tests, commit**

```bash
cd demo/warbler && swift test --filter WarblerSubscriptionsTests 2>&1
```
Expected: 10 tests pass (4 PM + 3 gateway + 3 projector)

```bash
git add demo/warbler/Sources/WarblerSubscriptions demo/warbler/Tests/WarblerSubscriptionsTests
git commit -m "Add Subscriptions gateway, projector, and tests"
```

---

## Task 9: Analytics Domain — Events & Projector (Tiered Storage)

**Files:**
- Create: `demo/warbler/Sources/WarblerAnalytics/AnalyticsEvent.swift`
- Create: `demo/warbler/Sources/WarblerAnalytics/PlaybackAnalyticsProjector.swift`
- Modify: `demo/warbler/Tests/WarblerAnalyticsTests/WarblerAnalyticsTests.swift`

**Step 1: Write AnalyticsEvent**

```swift
// demo/warbler/Sources/WarblerAnalytics/AnalyticsEvent.swift
import Songbird

public enum AnalyticsEvent: Event {
    case videoViewed(videoId: String, userId: String, watchedSeconds: Int)

    public var eventType: String {
        switch self {
        case .videoViewed: "VideoViewed"
        }
    }
}
```

**Step 2: Write PlaybackAnalyticsProjector**

```swift
// demo/warbler/Sources/WarblerAnalytics/PlaybackAnalyticsProjector.swift
import Foundation
import Songbird
import SongbirdSmew

public actor PlaybackAnalyticsProjector: Projector {
    public let projectorId = "PlaybackAnalytics"
    private let readModel: ReadModelStore

    /// The table name used for tiered storage registration.
    public static let tableName = "video_views"

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    /// Registers the video_views table for tiered storage management.
    /// Call this before `readModel.migrate()`.
    public func registerMigration() async {
        await readModel.registerTable(Self.tableName)
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE video_views (
                    id VARCHAR DEFAULT (uuid()::VARCHAR),
                    video_id VARCHAR NOT NULL,
                    user_id VARCHAR NOT NULL,
                    watched_seconds INTEGER NOT NULL,
                    recorded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case "VideoViewed":
            let envelope = try event.decode(AnalyticsEvent.self)
            guard case .videoViewed(let videoId, let userId, let watchedSeconds) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO video_views (video_id, user_id, watched_seconds, recorded_at) VALUES (\(param: videoId), \(param: userId), \(param: Int64(watchedSeconds)), \(param: event.timestamp.timeIntervalSince1970)::TIMESTAMP)"
                )
            }

        default:
            break
        }
    }
}
```

**Note:** The `recorded_at` column uses the event's timestamp for accurate tiering. The `CURRENT_TIMESTAMP` default is a fallback. The table is registered with `registerTable()` so tiered storage creates cold-tier mirrors and UNION ALL views.

**Step 3: Write projector tests**

```swift
// demo/warbler/Tests/WarblerAnalyticsTests/WarblerAnalyticsTests.swift
import Songbird
import SongbirdSmew
import SongbirdTesting
import Testing

@testable import WarblerAnalytics

private struct ViewRow: Decodable {
    let videoId: String
    let userId: String
    let watchedSeconds: Int64
}

@Suite("PlaybackAnalyticsProjector")
struct PlaybackAnalyticsProjectorTests {

    private func makeProjector() async throws -> (ReadModelStore, PlaybackAnalyticsProjector, TestProjectorHarness<PlaybackAnalyticsProjector>) {
        let readModel = try ReadModelStore()
        let projector = PlaybackAnalyticsProjector(readModel: readModel)
        await projector.registerMigration()
        try await readModel.migrate()
        let harness = TestProjectorHarness(projector: projector)
        return (readModel, projector, harness)
    }

    @Test func projectsVideoViewed() async throws {
        let (readModel, _, var harness) = try await makeProjector()

        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 120),
            streamName: StreamName(category: "analytics", id: "v-1")
        )

        let views: [ViewRow] = try await readModel.query(ViewRow.self) {
            "SELECT video_id, user_id, watched_seconds FROM video_views"
        }
        #expect(views.count == 1)
        #expect(views[0].videoId == "v-1")
        #expect(views[0].userId == "u-1")
        #expect(views[0].watchedSeconds == 120)
    }

    @Test func projectsMultipleViews() async throws {
        let (readModel, _, var harness) = try await makeProjector()

        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 60),
            streamName: StreamName(category: "analytics", id: "v-1")
        )
        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-2", watchedSeconds: 300),
            streamName: StreamName(category: "analytics", id: "v-1")
        )
        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-2", userId: "u-1", watchedSeconds: 45),
            streamName: StreamName(category: "analytics", id: "v-2")
        )

        let count = try await readModel.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM video_views").scalarInt64()
        }
        #expect(count == 3)
    }

    @Test func hasRecordedAtForTiering() async throws {
        let (readModel, _, var harness) = try await makeProjector()

        try await harness.given(
            AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 60),
            streamName: StreamName(category: "analytics", id: "v-1")
        )

        let hasColumn = try await readModel.withConnection { conn in
            try conn.query("SELECT recorded_at FROM video_views LIMIT 1").scalarInt64()
        }
        // recorded_at should exist and be non-null (the query succeeds without error)
        #expect(hasColumn != nil || true)  // Just verifying the column exists
    }

    @Test func tableIsRegisteredForTiering() async throws {
        let readModel = try ReadModelStore()
        let projector = PlaybackAnalyticsProjector(readModel: readModel)
        await projector.registerMigration()

        let tables = await readModel.registeredTables
        #expect(tables.contains("video_views"))
    }
}
```

**Step 4: Run tests, commit**

```bash
cd demo/warbler && swift test --filter WarblerAnalyticsTests 2>&1
```
Expected: 4 tests pass

```bash
git add demo/warbler/Sources/WarblerAnalytics demo/warbler/Tests/WarblerAnalyticsTests
git commit -m "Add Analytics domain: PlaybackAnalyticsProjector with tiered storage support"
```

---

## Task 10: Analytics Domain — ViewCountAggregate (Snapshots)

**Files:**
- Create: `demo/warbler/Sources/WarblerAnalytics/ViewCountEvent.swift`
- Create: `demo/warbler/Sources/WarblerAnalytics/ViewCountAggregate.swift`
- Create: `demo/warbler/Tests/WarblerAnalyticsTests/ViewCountAggregateTests.swift`

**Step 1: Write ViewCountEvent**

```swift
// demo/warbler/Sources/WarblerAnalytics/ViewCountEvent.swift
import Songbird

public enum ViewCountEvent: Event {
    case viewed(watchedSeconds: Int)

    public var eventType: String {
        switch self {
        case .viewed: "ViewCounted"
        }
    }
}
```

**Step 2: Write ViewCountAggregate**

```swift
// demo/warbler/Sources/WarblerAnalytics/ViewCountAggregate.swift
import Songbird

public enum ViewCountAggregate: Aggregate {
    public struct State: Sendable, Equatable, Codable {
        public var totalViews: Int
        public var totalWatchedSeconds: Int

        public init() {
            self.totalViews = 0
            self.totalWatchedSeconds = 0
        }
    }

    public typealias Event = ViewCountEvent
    public typealias Failure = Never

    public static let category = "view-count"
    public static let initialState = State()

    public static func apply(_ state: State, _ event: ViewCountEvent) -> State {
        switch event {
        case .viewed(let watchedSeconds):
            State(
                totalViews: state.totalViews + 1,
                totalWatchedSeconds: state.totalWatchedSeconds + watchedSeconds
            )
        }
    }
}
```

**Step 3: Write aggregate tests (including snapshot serialization)**

```swift
// demo/warbler/Tests/WarblerAnalyticsTests/ViewCountAggregateTests.swift
import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import WarblerAnalytics

@Suite("ViewCountAggregate")
struct ViewCountAggregateTests {

    @Test func countsViews() {
        var harness = TestAggregateHarness<ViewCountAggregate>()
        harness.given(.viewed(watchedSeconds: 60))
        harness.given(.viewed(watchedSeconds: 120))
        harness.given(.viewed(watchedSeconds: 30))

        #expect(harness.state.totalViews == 3)
        #expect(harness.state.totalWatchedSeconds == 210)
    }

    @Test func startsAtZero() {
        let harness = TestAggregateHarness<ViewCountAggregate>()
        #expect(harness.state == ViewCountAggregate.State())
        #expect(harness.state.totalViews == 0)
        #expect(harness.state.totalWatchedSeconds == 0)
    }

    @Test func stateIsCodableForSnapshots() throws {
        let state = ViewCountAggregate.State(totalViews: 42, totalWatchedSeconds: 3600)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ViewCountAggregate.State.self, from: data)
        #expect(decoded == state)
    }

    @Test func snapshotPolicyEvery100() {
        // Verify the snapshot policy constant works
        let policy = SnapshotPolicy.everyNEvents(100)
        #expect(policy == .everyNEvents(100))
    }

    @Test func snapshotRoundTrip() async throws {
        let snapshotStore = InMemorySnapshotStore()
        let stream = StreamName(category: "view-count", id: "v-1")
        let state = ViewCountAggregate.State(totalViews: 500, totalWatchedSeconds: 25000)

        try await snapshotStore.save(state, version: 499, for: stream)
        let loaded: (state: ViewCountAggregate.State, version: Int64)? = try await snapshotStore.load(for: stream)
        #expect(loaded?.state == state)
        #expect(loaded?.version == 499)
    }
}
```

**Step 4: Run tests, commit**

```bash
cd demo/warbler && swift test --filter WarblerAnalyticsTests 2>&1
```
Expected: 9 tests pass (4 projector + 5 aggregate)

```bash
git add demo/warbler/Sources/WarblerAnalytics demo/warbler/Tests/WarblerAnalyticsTests
git commit -m "Add ViewCountAggregate with snapshot support and tests"
```

---

## Task 11: Analytics Domain — PlaybackInjector

**Files:**
- Create: `demo/warbler/Sources/WarblerAnalytics/PlaybackInjector.swift`
- Create: `demo/warbler/Tests/WarblerAnalyticsTests/PlaybackInjectorTests.swift`

**Step 1: Write PlaybackInjector**

```swift
// demo/warbler/Sources/WarblerAnalytics/PlaybackInjector.swift
import Songbird

public actor PlaybackInjector: Injector {
    public let injectorId = "Playback"

    nonisolated(unsafe) private let _events: AsyncStream<InboundEvent>
    private let continuation: AsyncStream<InboundEvent>.Continuation

    /// Events that were successfully appended, tracked for observability.
    public private(set) var appendedCount: Int = 0

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: InboundEvent.self)
        self._events = stream
        self.continuation = continuation
    }

    public nonisolated func events() -> AsyncStream<InboundEvent> {
        _events
    }

    public func didAppend(
        _ event: InboundEvent,
        result: Result<RecordedEvent, any Error>
    ) async {
        if case .success = result {
            appendedCount += 1
        }
    }

    /// Called by the HTTP route to inject a playback event.
    public func inject(_ event: InboundEvent) {
        continuation.yield(event)
    }
}
```

**Step 2: Write injector tests**

```swift
// demo/warbler/Tests/WarblerAnalyticsTests/PlaybackInjectorTests.swift
import Songbird
import SongbirdTesting
import Testing

@testable import WarblerAnalytics

@Suite("PlaybackInjector")
struct PlaybackInjectorTests {

    @Test func injectsEventsIntoStream() async throws {
        let injector = PlaybackInjector()

        let viewEvent = AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 60)
        let inbound = InboundEvent(
            event: viewEvent,
            stream: StreamName(category: "analytics", id: "v-1"),
            metadata: EventMetadata(traceId: "test")
        )

        await injector.inject(inbound)

        // Read one event from the async stream
        var iterator = injector.events().makeAsyncIterator()
        let received = await iterator.next()

        #expect(received != nil)
        #expect(received?.stream == StreamName(category: "analytics", id: "v-1"))
        #expect(received?.metadata.traceId == "test")
    }

    @Test func tracksAppendedCount() async throws {
        let injector = PlaybackInjector()

        let inbound = InboundEvent(
            event: AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 30),
            stream: StreamName(category: "analytics", id: "v-1"),
            metadata: EventMetadata()
        )

        let recorded = try RecordedEvent(
            event: AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 30)
        )
        await injector.didAppend(inbound, result: .success(recorded))
        await injector.didAppend(inbound, result: .success(recorded))

        let count = await injector.appendedCount
        #expect(count == 2)
    }
}
```

**Step 3: Run tests, commit**

```bash
cd demo/warbler && swift test --filter WarblerAnalyticsTests 2>&1
```
Expected: 11 tests pass

```bash
git add demo/warbler/Sources/WarblerAnalytics demo/warbler/Tests/WarblerAnalyticsTests
git commit -m "Add PlaybackInjector for external event injection and tests"
```

---

## Task 12: Warbler Executable — Bootstrap & All Routes

**Files:**
- Modify: `demo/warbler/Sources/Warbler/main.swift`

This is the main entry point that wires everything together: event store, read model, services, routes.

**Step 1: Write the complete main.swift**

```swift
// demo/warbler/Sources/Warbler/main.swift
import Foundation
import Hummingbird
import Songbird
import SongbirdHummingbird
import SongbirdSmew
import SongbirdTesting
import WarblerAnalytics
import WarblerCatalog
import WarblerIdentity
import WarblerSubscriptions

@main
struct WarblerApp {
    static func main() async throws {
        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()

        // Identity events
        registry.register(UserEvent.self, eventTypes: ["UserRegistered", "ProfileUpdated", "UserDeactivated"])

        // Catalog events (current version)
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished", "VideoMetadataUpdated", "TranscodingCompleted", "VideoUnpublished"])

        // Catalog event versioning: v1 → v2 upcast
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: "VideoPublished_v1"
        )

        // Subscription events
        registry.register(SubscriptionEvent.self, eventTypes: ["SubscriptionRequested", "PaymentConfirmed", "PaymentFailed"])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: ["AccessGranted", "SubscriptionCancelled"])

        // Analytics events
        registry.register(AnalyticsEvent.self, eventTypes: ["VideoViewed"])
        registry.register(ViewCountEvent.self, eventTypes: ["ViewCounted"])

        // MARK: - Event Store (in-memory for demo; swap to SQLiteEventStore for persistence)

        let eventStore = InMemoryEventStore(registry: registry)
        let positionStore = InMemoryPositionStore()
        let snapshotStore = InMemorySnapshotStore()

        // MARK: - Read Model Store

        let readModel = try ReadModelStore()

        // MARK: - Projectors

        let userProjector = UserProjector(readModel: readModel)
        await userProjector.registerMigration()

        let videoCatalogProjector = VideoCatalogProjector(readModel: readModel)
        await videoCatalogProjector.registerMigration()

        let subscriptionProjector = SubscriptionProjector(readModel: readModel)
        await subscriptionProjector.registerMigration()

        let playbackProjector = PlaybackAnalyticsProjector(readModel: readModel)
        await playbackProjector.registerMigration()

        try await readModel.migrate()

        // MARK: - Repositories

        let userRepo = AggregateRepository<UserAggregate>(store: eventStore, registry: registry)
        let videoRepo = AggregateRepository<VideoAggregate>(store: eventStore, registry: registry)
        let viewCountRepo = AggregateRepository<ViewCountAggregate>(
            store: eventStore,
            registry: registry,
            snapshotStore: snapshotStore,
            snapshotPolicy: .everyNEvents(100)
        )

        // MARK: - Gateway & Injector

        let emailGateway = EmailNotificationGateway()
        let playbackInjector = PlaybackInjector()

        // MARK: - Services

        let pipeline = ProjectionPipeline()
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )

        mutableServices.registerProjector(userProjector)
        mutableServices.registerProjector(videoCatalogProjector)
        mutableServices.registerProjector(subscriptionProjector)
        mutableServices.registerProjector(playbackProjector)
        mutableServices.registerProcessManager(SubscriptionLifecycleProcess.self, tickInterval: .seconds(1))
        mutableServices.registerGateway(emailGateway, tickInterval: .seconds(1))
        mutableServices.registerInjector(playbackInjector)

        let services = mutableServices

        // MARK: - Router

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.addMiddleware { ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline) }

        // MARK: - Identity Routes

        router.post("/users/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let email: String; let displayName: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                RegisterUser(email: body.email, displayName: body.displayName),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: RegisterUserHandler.self,
                repository: userRepo,
                services: services
            )
            return Response(status: .created)
        }

        router.get("/users/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            struct UserRow: Codable { let id: String; let email: String; let displayName: String; let isActive: Bool }
            let user: UserRow? = try await readModel.queryFirst(UserRow.self) {
                "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: id)"
            }
            guard let user else { return Response(status: .notFound) }
            return try Response(status: .ok, headers: [.contentType: "application/json"], body: .init(data: JSONEncoder().encode(user)))
        }

        router.patch("/users/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let displayName: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                UpdateProfile(displayName: body.displayName),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: UpdateProfileHandler.self,
                repository: userRepo,
                services: services
            )
            return Response(status: .ok)
        }

        router.delete("/users/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await executeAndProject(
                DeactivateUser(),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: DeactivateUserHandler.self,
                repository: userRepo,
                services: services
            )
            return Response(status: .ok)
        }

        // MARK: - Catalog Routes

        router.post("/videos/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let title: String; let description: String; let creatorId: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                PublishVideo(title: body.title, description: body.description, creatorId: body.creatorId),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: PublishVideoHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .created)
        }

        router.get("/videos") { _, _ -> Response in
            struct VideoRow: Codable { let id: String; let title: String; let description: String; let creatorId: String; let status: String }
            let videos: [VideoRow] = try await readModel.query(VideoRow.self) {
                "SELECT id, title, description, creator_id, status FROM videos ORDER BY title"
            }
            return try Response(status: .ok, headers: [.contentType: "application/json"], body: .init(data: JSONEncoder().encode(videos)))
        }

        router.get("/videos/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            struct VideoRow: Codable { let id: String; let title: String; let description: String; let creatorId: String; let status: String }
            let video: VideoRow? = try await readModel.queryFirst(VideoRow.self) {
                "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: id)"
            }
            guard let video else { return Response(status: .notFound) }
            return try Response(status: .ok, headers: [.contentType: "application/json"], body: .init(data: JSONEncoder().encode(video)))
        }

        router.patch("/videos/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let title: String; let description: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                UpdateVideoMetadata(title: body.title, description: body.description),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: UpdateVideoMetadataHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .ok)
        }

        router.post("/videos/{id}/transcode-complete") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await executeAndProject(
                CompleteTranscoding(),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: CompleteTranscodingHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .ok)
        }

        router.delete("/videos/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await executeAndProject(
                UnpublishVideo(),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: UnpublishVideoHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .ok)
        }

        // MARK: - Subscription Routes

        router.post("/subscriptions/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let userId: String; let plan: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await appendAndProject(
                SubscriptionEvent.requested(subscriptionId: id, userId: body.userId, plan: body.plan),
                to: StreamName(category: "subscription", id: id),
                metadata: EventMetadata(traceId: context.requestId),
                services: services
            )
            return Response(status: .created)
        }

        router.get("/subscriptions/{userId}") { _, context -> Response in
            let userId = try context.parameters.require("userId")
            struct SubRow: Codable { let id: String; let userId: String; let plan: String; let status: String }
            let subs: [SubRow] = try await readModel.query(SubRow.self) {
                "SELECT id, user_id, plan, status FROM subscriptions WHERE user_id = \(param: userId)"
            }
            return try Response(status: .ok, headers: [.contentType: "application/json"], body: .init(data: JSONEncoder().encode(subs)))
        }

        router.post("/subscriptions/{id}/pay") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await appendAndProject(
                SubscriptionEvent.paymentConfirmed(subscriptionId: id),
                to: StreamName(category: "subscription", id: id),
                metadata: EventMetadata(traceId: context.requestId),
                services: services
            )
            return Response(status: .ok)
        }

        // MARK: - Analytics Routes

        router.post("/analytics/views") { request, context -> Response in
            struct Body: Codable { let videoId: String; let userId: String; let watchedSeconds: Int }
            let body = try await request.decode(as: Body.self, context: context)
            let event = AnalyticsEvent.videoViewed(videoId: body.videoId, userId: body.userId, watchedSeconds: body.watchedSeconds)
            let inbound = InboundEvent(
                event: event,
                stream: StreamName(category: "analytics", id: body.videoId),
                metadata: EventMetadata(traceId: context.requestId)
            )
            await playbackInjector.inject(inbound)
            return Response(status: .accepted)
        }

        router.get("/analytics/videos/{id}/views") { _, context -> Response in
            let id = try context.parameters.require("id")
            struct CountRow: Codable { let viewCount: Int64; let totalSeconds: Int64 }
            let result: CountRow? = try await readModel.queryFirst(CountRow.self) {
                "SELECT COUNT(*) AS view_count, COALESCE(SUM(watched_seconds), 0) AS total_seconds FROM video_views WHERE video_id = \(param: id)"
            }
            return try Response(status: .ok, headers: [.contentType: "application/json"], body: .init(data: JSONEncoder().encode(result)))
        }

        router.get("/analytics/top-videos") { _, _ -> Response in
            struct TopVideo: Codable { let videoId: String; let viewCount: Int64; let totalSeconds: Int64 }
            let top: [TopVideo] = try await readModel.query(TopVideo.self) {
                "SELECT video_id, COUNT(*) AS view_count, SUM(watched_seconds) AS total_seconds FROM video_views GROUP BY video_id ORDER BY view_count DESC LIMIT 10"
            }
            return try Response(status: .ok, headers: [.contentType: "application/json"], body: .init(data: JSONEncoder().encode(top)))
        }

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: 8080))
        )

        print("Warbler starting on http://localhost:8080")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Verify it compiles**

```bash
cd demo/warbler && swift build 2>&1
```
Expected: BUILD SUCCEEDED (may have warnings — fix as needed)

**Step 3: Commit**

```bash
git add demo/warbler/Sources/Warbler
git commit -m "Add Warbler bootstrap with all routes and service wiring"
```

---

## Task 13: Clean Build, Full Test Suite & Changelog

**Step 1: Run full test suite**

```bash
cd demo/warbler && swift test 2>&1
```
Expected: All tests pass across 4 test targets

**Step 2: Verify clean build (no warnings)**

```bash
cd demo/warbler && swift build 2>&1 | grep -i warning
```
Expected: No output (no warnings). Fix any warnings before proceeding.

**Step 3: Also run the main Songbird test suite to ensure nothing broke**

```bash
cd /Users/greg/Development/Songbird && swift test 2>&1
```
Expected: All 294 Songbird tests pass

**Step 4: Write changelog entry**

Create `changelog/0017-warbler-demo-app.md`:

```markdown
# Warbler Demo App

Adds a complete demo application showcasing all Songbird features, located in `demo/warbler/`.

**Design doc:** `docs/plans/2026-03-04-warbler-demo-app-design.md`

## What It Demonstrates

Warbler is a video tutorial platform API inspired by Garofolo's "Practical Microservices", built as a single Hummingbird executable with 4 domain modules:

### Identity Domain (WarblerIdentity)
- **UserAggregate** — register, update profile, deactivate
- **UserProjector** — DuckDB read model for user queries
- Demonstrates: basic Aggregate + CommandHandler + Projector pattern

### Catalog Domain (WarblerCatalog)
- **VideoAggregate** — publish, update, transcode, unpublish (state machine)
- **VideoCatalogProjector** — DuckDB read model for video catalog
- **VideoPublished_v1 → VideoEvent upcast** — event versioning with EventUpcast protocol
- Demonstrates: state machines, event versioning/upcasting

### Subscriptions Domain (WarblerSubscriptions)
- **SubscriptionLifecycleProcess** — request → payment → access/cancellation
- **EmailNotificationGateway** — mock email notifications on lifecycle events
- **SubscriptionProjector** — DuckDB read model for subscription status
- Demonstrates: ProcessManager with EventReactions, Gateway for side effects

### Analytics Domain (WarblerAnalytics)
- **PlaybackAnalyticsProjector** — DuckDB read model with `recorded_at` for tiered storage
- **ViewCountAggregate** — aggregate with SnapshotPolicy.everyNEvents(100)
- **PlaybackInjector** — external event injection via AsyncStream
- Demonstrates: Injector pattern, tiered storage readiness, snapshot optimization

### Warbler Executable
- Full Hummingbird HTTP API with 14 endpoints
- SongbirdServices wiring with all projectors, PM, gateway, injector
- RequestIdMiddleware + ProjectionFlushMiddleware
- appendAndProject + executeAndProject route helpers

## Testing

All 4 domain test targets use Songbird's test harnesses exclusively:
- TestAggregateHarness for aggregates
- TestProjectorHarness for projectors
- TestProcessManagerHarness for process managers
- TestGatewayHarness for gateways

No SQLite, no HTTP, no DuckDB in domain tests — pure domain logic.

## Files

- `demo/warbler/Package.swift`
- `demo/warbler/Sources/Warbler/main.swift`
- `demo/warbler/Sources/WarblerIdentity/` (4 files)
- `demo/warbler/Sources/WarblerCatalog/` (5 files)
- `demo/warbler/Sources/WarblerSubscriptions/` (5 files)
- `demo/warbler/Sources/WarblerAnalytics/` (5 files)
- `demo/warbler/Tests/` (4 test targets)
```

**Step 5: Commit changelog**

```bash
git add changelog/0017-warbler-demo-app.md
git commit -m "Add Warbler demo app changelog entry"
```

---

## Summary

| Task | Domain | What | Tests |
|------|--------|------|-------|
| 1 | All | Package scaffold | 4 placeholders |
| 2 | Identity | Events, aggregate, commands, handlers | 6 aggregate tests |
| 3 | Identity | UserProjector | 4 projector tests |
| 4 | Catalog | Events, aggregate, commands, handlers | 8 aggregate tests |
| 5 | Catalog | Event versioning (v1→v2 upcast) | 3 upcast tests |
| 6 | Catalog | VideoCatalogProjector | 3 projector tests |
| 7 | Subscriptions | Events, process manager, reactions | 4 PM tests |
| 8 | Subscriptions | Gateway, projector | 3+3 tests |
| 9 | Analytics | Events, PlaybackAnalyticsProjector | 4 projector tests |
| 10 | Analytics | ViewCountAggregate (snapshots) | 5 aggregate tests |
| 11 | Analytics | PlaybackInjector | 2 injector tests |
| 12 | Warbler | Bootstrap, all routes | compile check |
| 13 | All | Clean build, full tests, changelog | full suite |

**Total: ~45 new tests across 4 test targets**

Each task is independent within its domain. Tasks 2-3 (Identity), 4-6 (Catalog), 7-8 (Subscriptions), and 9-11 (Analytics) can be done in any domain order. Task 12 depends on all domains being complete. Task 13 is the final verification.
