import Foundation

struct Mistake: Codable, Equatable, Identifiable {
    let ts: Date
    let wrong: String
    let right: String
    let rule: String
    let session: String?   // eski satırlarda yok — decoder tolere eder

    var id: String { "\(ts.timeIntervalSince1970)-\(wrong)-\(right)" }

    init(ts: Date, wrong: String, right: String, rule: String, session: String? = nil) {
        self.ts = ts; self.wrong = wrong; self.right = right; self.rule = rule; self.session = session
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Tek JSONL satırını çözer; bozuk satır tüm listeyi kırmasın diye nil döner
    static func parse(line: String) -> Mistake? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(Mistake.self, from: data)
    }

    static func parseLog(_ content: String) -> [Mistake] {
        content.split(separator: "\n").compactMap { parse(line: String($0)) }
    }
}
