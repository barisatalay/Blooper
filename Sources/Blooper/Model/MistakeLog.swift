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
        // Aynı kontrolde yakalanan hatalar birebir aynı ts'i taşır; sıralama yalnız ts'e
        // dayanırsa eşitlerde sözlük sırası (rastgele) kazanır ve liste her çizimde oynar.
        // Kırılım: eşit ts'te dosyadaki son görülme sırası — deterministik ve doğal.
        var lastIndex: [String: Int] = [:]
        var groups: [String: [Mistake]] = [:]
        for (i, m) in mistakes.enumerated() {
            let key = "\(m.wrong)→\(m.right)"
            groups[key, default: []].append(m)
            lastIndex[key] = i
        }
        return groups.map { key, group in
            let last = group.max { $0.ts < $1.ts }!
            return (key, GroupedMistake(wrong: last.wrong, right: last.right, rule: last.rule,
                                        count: group.count, lastTs: last.ts))
        }
        .sorted { a, b in
            if a.1.lastTs != b.1.lastTs { return a.1.lastTs > b.1.lastTs }
            return (lastIndex[a.0] ?? 0) > (lastIndex[b.0] ?? 0)
        }
        .map { $0.1 }
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
