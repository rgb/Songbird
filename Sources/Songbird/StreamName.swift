import Foundation

public struct StreamName: Sendable, Hashable, Codable, CustomStringConvertible {
    public let category: String
    public let id: String?

    public init(category: String, id: String? = nil) {
        precondition(!category.isEmpty, "StreamName category must not be empty")
        precondition(!category.contains("-"), "StreamName category must not contain hyphens (used as delimiter)")
        if let id {
            precondition(!id.isEmpty, "StreamName id must not be empty (use nil for category streams)")
        }
        self.category = category
        self.id = id
    }

    public var isCategory: Bool { id == nil }

    public var description: String {
        if let id { "\(category)-\(id)" } else { category }
    }
}
