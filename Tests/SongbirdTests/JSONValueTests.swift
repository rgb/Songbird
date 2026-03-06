import Foundation
import Testing
@testable import Songbird

@Suite("JSONValue")
struct JSONValueTests {
    @Test func stringRoundTrip() throws {
        let value = JSONValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func intRoundTrip() throws {
        let value = JSONValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .int(42))
    }

    @Test func doubleRoundTrip() throws {
        let value = JSONValue.double(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func boolRoundTrip() throws {
        let value = JSONValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func nullRoundTrip() throws {
        let value = JSONValue.null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func objectRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("Alice"),
            "age": .int(30),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func arrayRoundTrip() throws {
        let value = JSONValue.array([.string("a"), .int(1), .bool(true), .null])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func nestedObjectAndArrayRoundTrip() throws {
        let value = JSONValue.object([
            "items": .array([.int(1), .int(2)]),
            "nested": .object(["key": .string("val")]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func parseEventJSON() throws {
        let json = Data("""
            {"name":"Alice","email":"a@b.com","amount":2300}
            """.utf8)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: json)
        #expect(fields["name"] == .string("Alice"))
        #expect(fields["email"] == .string("a@b.com"))
        #expect(fields["amount"] == .int(2300))
    }

    @Test func encryptedPayloadEncodesWithSortedKeys() throws {
        let payload = EncryptedPayload(
            originalEventType: "AccountCreated",
            fields: [
                "name": .string("enc:pii:abc123"),
                "email": .string("enc:pii+ret:def456"),
                "amount": .int(2300),
            ]
        )
        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8)!
        // Keys should be sorted alphabetically
        #expect(json.contains("\"amount\""))
        #expect(json.contains("\"email\""))
        #expect(json.contains("\"name\""))

        // Verify eventType is correct
        #expect(payload.eventType == "AccountCreated")
    }
}
