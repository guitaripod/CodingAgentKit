import Foundation
import Testing

@testable import AgentCore

@Suite struct JSONValueTests {
    @Test func everyKindKeepsItsKindWhateverOrderItIsTried() throws {
        let json = #"[true,false,0,1,-7,1.5,"1","true",null,[],{},{"a":[false,2,2.25,"x"]}]"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(
            value
                == .array([
                    .bool(true), .bool(false), .integer(0), .integer(1), .integer(-7), .number(1.5),
                    .string("1"), .string("true"), .null, .array([]), .object([:]),
                    .object(["a": .array([.bool(false), .integer(2), .number(2.25), .string("x")])]),
                ]))
    }

    @Test func anEventSaysWhetherItMentionsAWordByteForByte() {
        let event = SSEvent(id: nil, type: nil, data: #"{"type":"session.text.delta","data":{"sessionID":"ses_Ab","delta":"héllo"}}"#)
        #expect(event.mentions("ses_Ab"))
        #expect(event.mentions("\"session.text.delta\""))
        #expect(event.mentions("héllo"))
        #expect(!event.mentions("ses_Abc"))
        #expect(!event.mentions("ses_ab"))
        #expect(event.mentions(""))
        #expect(!SSEvent(id: nil, type: nil, data: "").mentions("x"))
        #expect(!SSEvent(id: nil, type: nil, data: "ab").mentions("abc"))
    }

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
