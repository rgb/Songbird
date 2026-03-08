import Songbird

public enum ViewCountEvent: Event, Equatable {
    case viewed(watchedSeconds: Int)

    public var eventType: String {
        switch self {
        case .viewed: ViewCountEventTypes.viewCounted
        }
    }
}
