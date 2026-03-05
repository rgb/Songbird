import Songbird

public enum ViewCountAggregate: Aggregate {
    public struct State: Sendable, Equatable, Codable {
        public var totalViews: Int
        public var totalWatchedSeconds: Int

        public init() {
            self.totalViews = 0
            self.totalWatchedSeconds = 0
        }

        public init(totalViews: Int, totalWatchedSeconds: Int) {
            self.totalViews = totalViews
            self.totalWatchedSeconds = totalWatchedSeconds
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
