import SwiftUI
import ServiceManagement

struct MenuView: View {
    @ObservedObject var store: MistakeStore
    let installer: HookInstaller
    let statuslineInstaller: StatuslineInstaller
    @State private var blooperActive = false
    @State private var statusInfo: String?
    @State private var notificationsOn = Notifier.notificationsEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private static let claudeFound: Bool = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/claude", "/opt/homebrew/bin/claude",
                home + "/.claude/local/claude", home + "/.local/bin/claude"]
            .contains { fm.isExecutableFile(atPath: $0) }
    }()

    private var grouped: [GroupedMistake] { MistakeLog.grouped(store.mistakes) }
    private var week: [Int] { MistakeLog.weekCounts(store.mistakes, now: Date(), calendar: .current) }
    private var today: Int { MistakeLog.countToday(store.mistakes, now: Date(), calendar: .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if Bundle.main.bundlePath.contains("/AppTranslocation/") {
                Text("Move Blooper to /Applications and relaunch — some features are unreliable from this location.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !Self.claudeFound {
                Text("Claude Code not found — checks will not run.")
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
                // MenuBarExtra penceresi ScrollView'un ideal yüksekliğini sıfıra yakın seçip
                // listeyi eziyor — içerik sayısına göre açık yükseklik verilir (üst sınırlı)
                let listHeight = min(CGFloat(grouped.prefix(30).count) * 84 + 8, 380)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(grouped.prefix(30)) { g in MistakeCard(mistake: g) }
                    }
                }
                .frame(height: listHeight)
            }

            Divider()
            // Tek anahtar hem hook'u hem statusline'ı yönetir
            Toggle("Blooper active", isOn: $blooperActive)
                .onChange(of: blooperActive) { _, on in
                    // Başarısızlıkta programatik geri-çekme onChange'i yeniden tetikler — döngüyü kes
                    guard on != installer.isInstalled() else { return }
                    setBlooperActive(on)
                }
            Toggle("Notifications", isOn: $notificationsOn)
                .onChange(of: notificationsOn) { _, on in Notifier.setNotificationsEnabled(on) }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    // Kayıt başarısızsa toggle'ı gerçeğe geri çek
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            HStack {
                Button("Export Markdown") { exportMarkdown() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            if let statusInfo { Text(statusInfo).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { blooperActive = installer.isInstalled() }
    }

    private func setBlooperActive(_ on: Bool) {
        var infos: [String] = []
        do {
            if on {
                try installer.install()
                do {
                    if let m = try statuslineInstaller.install() { infos.append(m) }
                } catch StatuslineError.alreadyContainsBlooper {
                    // Statusline zaten Blooper içeriyor — hook kurulumu yine geçerli
                    infos.append("Statusline already includes Blooper — left as is.")
                }
            } else {
                try installer.uninstall()
                if let m = try statuslineInstaller.uninstall() { infos.append(m) }
            }
            statusInfo = infos.first ?? (on
                ? "Blooper active — mistakes appear after your next prompts."
                : "Blooper inactive — hook and statusline removed.")
        } catch {
            statusInfo = "Couldn't parse settings.json — left untouched. Fix it manually and retry."
        }
        blooperActive = installer.isInstalled()
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "english-mistakes.md"
        if panel.runModal() == .OK, let url = panel.url {
            try? MarkdownExporter.render(store.mistakes).write(to: url, atomically: true, encoding: .utf8)
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
