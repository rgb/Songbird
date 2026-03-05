import Foundation
import Testing
@testable import Songbird

@Suite("Shreddable")
struct ShreddableTests {
    @Test func valueEncodesAsRawValue() throws {
        let value: Shreddable<String> = .value("Alice")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"Alice\"")
    }

    @Test func shreddedEncodesAsNull() throws {
        let value: Shreddable<String> = .shredded
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "null")
    }

    @Test func decodesValueFromRawValue() throws {
        let data = Data("\"Alice\"".utf8)
        let decoded = try JSONDecoder().decode(Shreddable<String>.self, from: data)
        #expect(decoded == .value("Alice"))
    }

    @Test func decodesNullAsShredded() throws {
        let data = Data("null".utf8)
        let decoded = try JSONDecoder().decode(Shreddable<String>.self, from: data)
        #expect(decoded == .shredded)
    }

    @Test func integerRoundTrip() throws {
        let value: Shreddable<Int> = .value(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Shreddable<Int>.self, from: data)
        #expect(decoded == .value(42))
    }

    @Test func boolRoundTrip() throws {
        let value: Shreddable<Bool> = .value(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Shreddable<Bool>.self, from: data)
        #expect(decoded == .value(true))
    }

    @Test func stringLiteral() {
        let value: Shreddable<String> = "hello"
        #expect(value == .value("hello"))
    }

    @Test func integerLiteral() {
        let value: Shreddable<Int> = 42
        #expect(value == .value(42))
    }

    @Test func floatLiteral() {
        let value: Shreddable<Double> = 3.14
        #expect(value == .value(3.14))
    }

    @Test func booleanLiteral() {
        let value: Shreddable<Bool> = true
        #expect(value == .value(true))
    }

    @Test func equality() {
        #expect(Shreddable<String>.value("a") == .value("a"))
        #expect(Shreddable<String>.value("a") != .value("b"))
        #expect(Shreddable<String>.shredded == .shredded)
        #expect(Shreddable<String>.value("a") != .shredded)
    }

    @Test func structRoundTrip() throws {
        struct Person: Codable, Equatable {
            let name: Shreddable<String>
            let age: Int
        }
        let person = Person(name: "Alice", age: 30)
        let data = try JSONEncoder().encode(person)
        let decoded = try JSONDecoder().decode(Person.self, from: data)
        #expect(decoded == person)
    }

    @Test func structWithShreddedField() throws {
        struct Person: Codable, Equatable {
            let name: Shreddable<String>
            let age: Int
        }
        let json = Data("{\"name\":null,\"age\":30}".utf8)
        let decoded = try JSONDecoder().decode(Person.self, from: json)
        #expect(decoded.name == .shredded)
        #expect(decoded.age == 30)
    }
}
