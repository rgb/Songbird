public protocol Aggregate {
    associatedtype State: Sendable, Equatable
    associatedtype Event: Songbird.Event
    associatedtype Failure: Error

    static var category: String { get }
    static var initialState: State { get }
    static func apply(_ state: State, _ event: Event) -> State
}
