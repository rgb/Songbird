public protocol Message: Sendable, Codable, Equatable {
    var messageType: String { get }
}
