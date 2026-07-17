import Foundation
import Testing

@testable import AgentCore

@Suite struct JSONValueTests {
    @Test func roundTripAndSubscript() throws {
        let json = #"{"a":1,"b":"two","c":[true,null],"d":{"e":3.5}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))

        #expect(value["a"] == .integer(1))
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

    @Test func integersAboveDoublePrecisionSurviveRoundTrip() throws {
        let big: Int64 = 9_007_199_254_740_993
        let json = "{\"id\":\(big)}"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["id"] == .integer(big))
        #expect(value["id"]?.intValue == big)

        let reencoded = try JSONEncoder().encode(value)
        #expect(String(decoding: reencoded, as: UTF8.self).contains("\(big)"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: reencoded) == value)
    }

    @Test func fractionalNumbersStayNumbers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("3.5".utf8))
        #expect(value == .number(3.5))
        #expect(value.intValue == nil)
    }

    @Test func intValueBridgesBothNumericCases() {
        #expect(JSONValue.integer(42).intValue == 42)
        #expect(JSONValue.number(42).intValue == 42)
        #expect(JSONValue.number(42).doubleValue == 42)
        #expect(JSONValue.integer(42).doubleValue == 42)
    }

    @Test func compactDescriptionRendersIntegersWithoutTrailingZero() {
        #expect(JSONValue.integer(3).compactDescription == "3")
        #expect(JSONValue.number(3).compactDescription == "3")
        #expect(JSONValue.string("hi").compactDescription == "hi")
    }
}
