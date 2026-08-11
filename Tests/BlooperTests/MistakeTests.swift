import XCTest
@testable import Blooper

final class MistakeTests: XCTestCase {
    func testParsesValidLine() throws {
        let line = #"{"ts":"2026-08-11T14:02:11Z","wrong":"I am agree","right":"I agree","rule":"'agree' is a verb"}"#
        let m = try XCTUnwrap(Mistake.parse(line: line))
        XCTAssertEqual(m.wrong, "I am agree")
        XCTAssertEqual(m.right, "I agree")
        XCTAssertEqual(m.rule, "'agree' is a verb")
    }

    func testMalformedLineReturnsNil() {
        XCTAssertNil(Mistake.parse(line: "not json"))
        XCTAssertNil(Mistake.parse(line: #"{"ts":"2026-08-11T14:02:11Z","wrong":"x"}"#)) // eksik alan
        XCTAssertNil(Mistake.parse(line: #"{"ts":"bozuk-tarih","wrong":"a","right":"b","rule":"c"}"#))
    }

    func testParseLogSkipsBadLinesKeepsGood() {
        let content = """
        {"ts":"2026-08-11T14:02:11Z","wrong":"a","right":"b","rule":"c"}
        garbage
        {"ts":"2026-08-11T15:00:00Z","wrong":"d","right":"e","rule":"f"}
        """
        let all = Mistake.parseLog(content)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[1].wrong, "d")
    }

    func testParseLogEmptyContent() {
        XCTAssertEqual(Mistake.parseLog(""), [])
    }
}
