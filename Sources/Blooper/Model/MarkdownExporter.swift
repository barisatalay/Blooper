import Foundation

enum MarkdownExporter {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: #"\|"#).replacingOccurrences(of: "\n", with: " ")
    }

    static func render(_ mistakes: [Mistake]) -> String {
        guard !mistakes.isEmpty else { return "# English Mistakes\n\nNo mistakes logged yet.\n" }
        let groups = MistakeLog.grouped(mistakes)
        var out = "# English Mistakes\n\n| Date | Wrong | Right | Rule | Count |\n|---|---|---|---|---|\n"
        for g in groups {
            out += "| \(dayFormatter.string(from: g.lastTs)) | \(esc(g.wrong)) | \(esc(g.right)) | \(esc(g.rule)) | \(g.count) |\n"
        }
        out += "\n## Most frequent\n\n"
        for g in groups.sorted(by: { $0.count > $1.count }).prefix(10) {
            out += "- **\(esc(g.wrong)) → \(esc(g.right))** — \(g.count)x (\(esc(g.rule)))\n"
        }
        return out
    }
}
