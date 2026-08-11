import XCTest
@testable import Blooper

final class MarkdownExporterTests: XCTestCase {
    private func m(_ iso: String, _ wrong: String, _ right: String) -> Mistake {
        Mistake(ts: ISO8601DateFormatter().date(from: iso)!, wrong: wrong, right: right, rule: "some rule")
    }

    func testRenderContainsTableAndTopSection() {
        let md = MarkdownExporter.render([
            m("2026-08-11T10:00:00Z", "I am agree", "I agree"),
            m("2026-08-11T11:00:00Z", "I am agree", "I agree"),
            m("2026-08-10T09:00:00Z", "teh", "the"),
        ])
        XCTAssertTrue(md.contains("| Date | Wrong | Right | Rule | Count |"))
        XCTAssertTrue(md.contains("I am agree"))
        XCTAssertTrue(md.contains("## Most frequent"))
        // en sık bölümünde count=2 önce gelmeli
        let freqPart = md.components(separatedBy: "## Most frequent")[1]
        XCTAssertLessThan(freqPart.range(of: "I am agree")!.lowerBound, freqPart.range(of: "teh")!.lowerBound)
    }

    func testRenderEscapesPipes() {
        let md = MarkdownExporter.render([m("2026-08-11T10:00:00Z", "a|b", "a")])
        XCTAssertTrue(md.contains(#"a\|b"#))
    }

    func testRenderEmpty() {
        XCTAssertTrue(MarkdownExporter.render([]).contains("No mistakes logged yet"))
    }
}
