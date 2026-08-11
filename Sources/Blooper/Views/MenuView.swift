import SwiftUI

struct MenuView: View {
    @ObservedObject var store: MistakeStore
    let installer: HookInstaller
    @State private var hookInstalled = false
    @State private var installError: String?

    private var grouped: [GroupedMistake] { MistakeLog.grouped(store.mistakes) }
    private var week: [Int] { MistakeLog.weekCounts(store.mistakes, now: Date(), calendar: .current) }
    private var today: Int { MistakeLog.countToday(store.mistakes, now: Date(), calendar: .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if Bundle.main.bundlePath.contains("/AppTranslocation/") {
                Text("Move Blooper to /Applications and relaunch — some features are unreliable from this location.")
                    .font(.caption).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("English mistakes").font(.title2).bold()
                Text("\(store.mistakes.count) logged · \(today) today")
                    .font(.caption).foregroundStyle(.secondary)
            }

            WeekChart(counts: week)

            if grouped.isEmpty {
                Text("No mistakes yet — start writing English prompts in Claude Code.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(grouped.prefix(30)) { g in MistakeCard(mistake: g) }
                    }
                }
                .frame(maxHeight: 380)
            }

            Divider()
            HStack {
                Button(hookInstalled ? "Remove hook" : "Install Claude Code hook") { toggleHook() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            if let installError { Text(installError).font(.caption).foregroundStyle(.red) }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { hookInstalled = installer.isInstalled() }
    }

    private func toggleHook() {
        do {
            if hookInstalled { try installer.uninstall() } else { try installer.install() }
            hookInstalled = installer.isInstalled()
            installError = nil
        } catch {
            installError = "Couldn't parse settings.json — left untouched. Fix it manually and retry."
        }
    }
}

struct MistakeCard: View {
    let mistake: GroupedMistake
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                (Text(mistake.wrong).foregroundStyle(.red).bold()
                 + Text(" → ")
                 + Text(mistake.right).foregroundStyle(.green).bold())
                    .font(.system(.body, design: .monospaced))
                if mistake.count > 1 {
                    Text("x\(mistake.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(mistake.lastTs, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Text(mistake.rule).font(.callout).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct WeekChart: View {
    let counts: [Int]
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EE"; return f
    }()
    var body: some View {
        let maxC = max(counts.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(counts.enumerated()), id: \.offset) { i, c in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.2 + 0.6 * Double(c) / Double(maxC)))
                        .frame(height: max(4, 60 * CGFloat(c) / CGFloat(maxC)))
                    Text(Self.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: i - 6, to: Date())!))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 80)
    }
}
