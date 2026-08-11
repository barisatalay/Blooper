import SwiftUI

@main
struct BlooperApp: App {
    @StateObject private var store: MistakeStore

    private let installer = HookInstaller(
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"))

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
            MenuView(store: store, installer: installer)
        } label: {
            // Menübar sayacı: bildirim izni verilmese de birincil sinyal
            let today = MistakeLog.countToday(store.mistakes, now: Date(), calendar: .current)
            Image(systemName: today > 0 ? "text.badge.xmark" : "text.badge.checkmark")
            if today > 0 { Text("\(today)") }
        }
        .menuBarExtraStyle(.window)
    }
}
