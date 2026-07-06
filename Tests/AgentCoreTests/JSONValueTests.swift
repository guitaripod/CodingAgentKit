import Foundation
import Testing

@testable import AgentCore

@Suite struct JSONValueTests {
    @Test func roundTripAndSubscript() throws {
        let json = #"{"a":1,"b":"two","c":[true,null],"d":{"e":3.5}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))

        #expect(value["a"] == .number(1))
        #expect(value["b"]?.stringValue == "two")
        #expect(value["d"]?["e"] == .number(3.5))
        #expect(value["c"] == .array([.bool(true), .null]))

        let reencoded = try JSONEncoder().encode(value)
        let roundTripped = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        #expect(roundTripped == value)
    }

    @Test func boolIsNotDecodedAsNumber() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
        #expect(value == .bool(true))
    }

    @Test func compactDescriptionRendersIntegersWithoutTrailingZero() {
        #expect(JSONValue.number(3).compactDescription == "3")
        #expect(JSONValue.string("hi").compactDescription == "hi")
    }
}
