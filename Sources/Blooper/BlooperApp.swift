import SwiftUI

// Menübar template ikonu: bundle'da varsa markalı silueti, yoksa SF Symbol'ü kullan
// (swift build/dev akışında bundle Resources'ı yoktur — fallback o yüzden şart)
private let menuBarIcon: NSImage? = {
    guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = true
    img.size = NSSize(width: 18, height: 18)
    return img
}()

@main
struct BlooperApp: App {
    @StateObject private var store: MistakeStore

    private let installer = HookInstaller(
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"))

    private let statuslineInstaller = StatuslineInstaller(
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        configURL: BlooperEnv.configFile,
        binDir: BlooperEnv.binDir,
        // Bundle yoksa (dev/swift run) son app açılışının senkronladığı kopya kullanılır
        templateURL: Bundle.main.url(forResource: "statusline-wrapper-template", withExtension: "sh")
            ?? BlooperEnv.binDir.appendingPathComponent("statusline-wrapper-template.sh"))

    init() {
        BlooperEnv.bootstrap()
        let s = MistakeStore(fileURL: BlooperEnv.mistakesFile)
        s.reload()
        s.onNewMistakes = { fresh in Notifier.notifyIfEnabled(fresh) }
        s.startWatching()
        _store = StateObject(wrappedValue: s)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store, installer: installer, statuslineInstaller: statuslineInstaller)
        } label: {
            // Menübar sayacı: bildirim izni verilmese de birincil sinyal
            let today = MistakeLog.countToday(store.mistakes, now: Date(), calendar: .current)
            if let menuBarIcon {
                Image(nsImage: menuBarIcon)
            } else {
                Image(systemName: today > 0 ? "text.badge.xmark" : "text.badge.checkmark")
            }
            if today > 0 { Text("\(today)") }
        }
        .menuBarExtraStyle(.window)
    }
}
