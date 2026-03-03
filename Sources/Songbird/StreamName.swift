import Foundation

public struct StreamName: Sendable, Hashable, Codable, CustomStringConvertible {
    public let category: String
    public let id: String?

    public init(category: String, id: String? = nil) {
        self.category = category
        self.id = id
    }

    public var isCategory: Bool { id == nil }

    public var description: String {
        if let id { "\(category)-\(id)" } else { category }
    }
}
