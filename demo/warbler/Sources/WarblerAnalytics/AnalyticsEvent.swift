import Songbird

public enum AnalyticsEvent: Event {
    case videoViewed(videoId: String, userId: String, watchedSeconds: Int)

    public var eventType: String {
        switch self {
        case .videoViewed: AnalyticsEventTypes.videoViewed
        }
    }
}
