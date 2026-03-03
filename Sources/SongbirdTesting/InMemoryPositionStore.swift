import Songbird

public actor InMemoryPositionStore: PositionStore {
    private var positions: [String: Int64] = [:]

    public init() {}

    public func load(subscriberId: String) async throws -> Int64? {
        positions[subscriberId]
    }

    public func save(subscriberId: String, globalPosition: Int64) async throws {
        positions[subscriberId] = globalPosition
    }
}
