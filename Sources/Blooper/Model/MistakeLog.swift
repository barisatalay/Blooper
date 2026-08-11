import Foundation

struct GroupedMistake: Identifiable, Equatable {
    let wrong: String
    let right: String
    let rule: String
    let count: Int
    let lastTs: Date
    var id: String { "\(wrong)→\(right)" }
}

enum MistakeLog {
    static func grouped(_ mistakes: [Mistake]) -> [GroupedMistake] {
        let dict = Dictionary(grouping: mistakes) { "\($0.wrong)→\($0.right)" }
        return dict.values.map { group in
            let last = group.max { $0.ts < $1.ts }!
            return GroupedMistake(wrong: last.wrong, right: last.right, rule: last.rule,
                                  count: group.count, lastTs: last.ts)
        }
        .sorted { $0.lastTs > $1.lastTs }
    }

    static func countToday(_ mistakes: [Mistake], now: Date, calendar: Calendar) -> Int {
        mistakes.filter { calendar.isDate($0.ts, inSameDayAs: now) }.count
    }

    static func weekCounts(_ mistakes: [Mistake], now: Date, calendar: Calendar) -> [Int] {
        (0..<7).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return 0 }
            return mistakes.filter { calendar.isDate($0.ts, inSameDayAs: day) }.count
        }
    }
}
