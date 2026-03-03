public protocol ProcessManager {
    associatedtype State: Sendable
    associatedtype InputEvent: Event
    associatedtype OutputCommand: Command

    static var processId: String { get }
    static var initialState: State { get }
    static func apply(_ state: State, _ event: InputEvent) -> State
    static func commands(_ state: State, _ event: InputEvent) -> [OutputCommand]
}
