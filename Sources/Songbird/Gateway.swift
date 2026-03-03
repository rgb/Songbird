public protocol Gateway: Sendable {
    var gatewayId: String { get }
    func handle(_ event: RecordedEvent) async throws
}
