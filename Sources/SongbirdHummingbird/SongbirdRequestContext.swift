import Foundation
import Hummingbird

public struct SongbirdRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public var requestId: String?

    public init(source: Source) {
        self.coreContext = .init(source: source)
        self.requestId = nil
    }
}
