import Foundation
import Testing

@testable import Songbird

@Suite("StreamName")
struct StreamNameTests {
    @Test func entityStreamHasCategoryAndId() {
        let stream = StreamName(category: "order", id: "abc-123")
        #expect(stream.category == "order")
        #expect(stream.id == "abc-123")
        #expect(stream.isCategory == false)
    }

    @Test func categoryStreamHasNilId() {
        let stream = StreamName(category: "order")
        #expect(stream.category == "order")
        #expect(stream.id == nil)
        #expect(stream.isCategory == true)
    }

    @Test func entityStreamDescription() {
        let stream = StreamName(category: "order", id: "abc-123")
        #expect(stream.description == "order-abc-123")
    }

    @Test func categoryStreamDescription() {
        let stream = StreamName(category: "order")
        #expect(stream.description == "order")
    }

    @Test func equalityByValue() {
        let a = StreamName(category: "order", id: "123")
        let b = StreamName(category: "order", id: "123")
        let c = StreamName(category: "order", id: "456")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func hashableForDictionaryKeys() {
        let stream = StreamName(category: "order", id: "123")
        var dict: [StreamName: Int] = [:]
        dict[stream] = 42
        #expect(dict[StreamName(category: "order", id: "123")] == 42)
    }

    @Test func codableRoundTrip() throws {
        let stream = StreamName(category: "order", id: "abc-123")
        let data = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode(StreamName.self, from: data)
        #expect(stream == decoded)
    }

    @Test func codableCategoryStreamRoundTrip() throws {
        let stream = StreamName(category: "order")
        let data = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode(StreamName.self, from: data)
        #expect(stream == decoded)
    }

    @Test func validCategoryIsAccepted() {
        let stream = StreamName(category: "order", id: "123")
        #expect(stream.category == "order")
        #expect(stream.id == "123")
    }

    @Test func categoryWithoutHyphensIsAccepted() {
        let stream = StreamName(category: "orderItem")
        #expect(stream.category == "orderItem")
        #expect(stream.isCategory == true)
    }
}
