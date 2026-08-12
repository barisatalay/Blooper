import XCTest
@testable import Blooper

final class MistakeLogTests: XCTestCase {
    // Fixture'lar UTC — takvim sistem timezone'una bırakılırsa gün sınırları makineye göre kayar
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func m(_ iso: String, _ wrong: String = "I am agree", _ right: String = "I agree") -> Mistake {
        Mistake(ts: date(iso), wrong: wrong, right: right, rule: "r")
    }

    func testGroupsSamePairAndCounts() {
        let list = [m("2026-08-11T10:00:00Z"), m("2026-08-11T11:00:00Z"), m("2026-08-11T12:00:00Z", "teh", "the")]
        let g = MistakeLog.grouped(list)
        XCTAssertEqual(g.count, 2)
        let agree = g.first { $0.wrong == "I am agree" }!
        XCTAssertEqual(agree.count, 2)
        XCTAssertEqual(agree.lastTs, date("2026-08-11T11:00:00Z"))
    }

    func testGroupedSortedByLastTsDesc() {
        let g = MistakeLog.grouped([m("2026-08-10T10:00:00Z", "a", "b"), m("2026-08-11T10:00:00Z", "c", "d")])
        XCTAssertEqual(g.first?.wrong, "c")
    }

    func testCountToday() {
        let now = date("2026-08-11T18:00:00Z")
        let list = [m("2026-08-11T01:00:00Z"), m("2026-08-10T23:00:00Z")]
        XCTAssertEqual(MistakeLog.countToday(list, now: now, calendar: cal), 1)
    }

    func testGroupedOrderIsStableForEqualTimestamps() {
        // Aynı ts'li gruplar (tek kontrolün çıktısı) her çağrıda aynı sırada dönmeli:
        // dosyadaki son görülme sırası, en yeni üstte
        let list = [m("2026-08-12T10:00:00Z", "a1", "b1"), m("2026-08-12T10:00:00Z", "a2", "b2"),
                    m("2026-08-12T10:00:00Z", "a3", "b3"), m("2026-08-12T10:00:00Z", "a4", "b4")]
        let first = MistakeLog.grouped(list).map(\.wrong)
        XCTAssertEqual(first, ["a4", "a3", "a2", "a1"])
        for _ in 0..<20 {
            XCTAssertEqual(MistakeLog.grouped(list).map(\.wrong), first, "sıra çağrılar arası oynamamalı")
        }
    }

    func testWeekCountsSevenBucketsOldestFirst() {
        let now = date("2026-08-11T18:00:00Z")
        let list = [m("2026-08-11T01:00:00Z"), m("2026-08-11T02:00:00Z"), m("2026-08-05T12:00:00Z"), m("2026-08-01T12:00:00Z")]
        let w = MistakeLog.weekCounts(list, now: now, calendar: cal)
        XCTAssertEqual(w.count, 7)
        XCTAssertEqual(w[6], 2)  // bugün
        XCTAssertEqual(w[0], 1)  // 6 gün önce (08-05)
        XCTAssertEqual(w.reduce(0, +), 3) // 08-01 pencere dışı
    }
}
