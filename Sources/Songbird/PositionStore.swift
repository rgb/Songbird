public protocol PositionStore: Sendable {
    func load(subscriberId: String) async throws -> Int64?
    func save(subscriberId: String, globalPosition: Int64) async throws
}
