public protocol Projector: Sendable {
    var projectorId: String { get }
    func apply(_ event: RecordedEvent) async throws
}
