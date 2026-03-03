public protocol Command: Message {
    var commandType: String { get }
}

extension Command {
    public var messageType: String { commandType }
}
