import Foundation
import Testing
@testable import Songbird

@Suite("CryptoShreddable")
struct CryptoShreddableTests {
    struct AccountCreated: Event, CryptoShreddable {
        let name: Shreddable<String>
        let email: Shreddable<String>
        let amount: Double
        var eventType: String { "AccountCreated" }
        static let fieldProtection: [String: FieldProtection] = [
            "name": .piiAndRetention(.seconds(86400 * 365 * 7)),
            "email": .pii,
        ]
    }

    @Test func fieldProtectionValues() {
        let protection = AccountCreated.fieldProtection
        #expect(protection["name"] == .piiAndRetention(.seconds(86400 * 365 * 7)))
        #expect(protection["email"] == .pii)
        #expect(protection["amount"] == nil)
    }

    @Test func piiReferenceKeyInMetadata() {
        let metadata = EventMetadata(piiReferenceKey: "entity-123")
        #expect(metadata.piiReferenceKey == "entity-123")
    }

    @Test func piiReferenceKeyDefaultsToNil() {
        let metadata = EventMetadata()
        #expect(metadata.piiReferenceKey == nil)
    }

    @Test func piiReferenceKeyEncodesAndDecodes() throws {
        let metadata = EventMetadata(piiReferenceKey: "abc-123")
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(EventMetadata.self, from: data)
        #expect(decoded.piiReferenceKey == "abc-123")
    }

    @Test func metadataWithoutPiiKeyStillDecodes() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(EventMetadata.self, from: json)
        #expect(decoded.piiReferenceKey == nil)
    }
}
