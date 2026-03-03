public protocol Command: Sendable {
    static var commandType: String { get }
}
