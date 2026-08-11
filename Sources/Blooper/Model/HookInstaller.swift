import Foundation

enum HookInstallerError: Error { case unparsableSettings }

struct HookInstaller {
    let settingsURL: URL

    // Boşluklu yol nedeniyle çift tırnaklı $HOME formu zorunlu; ~ tek tırnakta genişlemez
    static let hookCommand = "\"$HOME/Library/Application Support/Blooper/bin/hook.sh\""
    private static let marker = "Blooper/bin/hook.sh"

    private var newEntry: [String: Any] {
        ["hooks": [["type": "command", "command": Self.hookCommand]]]
    }

    func isInstalled() -> Bool {
        guard let root = try? readSettings() else { return false }
        return entries(root).contains(where: Self.isOurs)
    }

    func install() throws {
        var root = try readSettingsOrEmpty()
        var list = entries(root)
        guard !list.contains(where: Self.isOurs) else { return }
        backupIfExists()
        list.append(newEntry)
        try writeSettings(setEntries(list, in: &root))
    }

    func uninstall() throws {
        // Dosya hiç yoksa yaratma — sökülecek bir şey de yok
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var root = try readSettingsOrEmpty()
        let list = entries(root).filter { !Self.isOurs($0) }
        backupIfExists()
        // Not: JSONSerialization yazımı dosyayı yeniden biçimler (pretty + sorted) — bilinçli kabul
        try writeSettings(setEntries(list, in: &root))
    }

    // MARK: - iç yardımcılar

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let cmds = (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        return cmds.contains { $0.contains(marker) }
    }

    private func entries(_ root: [String: Any]) -> [[String: Any]] {
        ((root["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]]) ?? []
    }

    private func setEntries(_ list: [[String: Any]], in root: inout [String: Any]) -> [String: Any] {
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        hooks["UserPromptSubmit"] = list
        root["hooks"] = hooks
        return root
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.unparsableSettings
        }
        return obj
    }

    private func readSettingsOrEmpty() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        return try readSettings()   // parse edilemeyen dosyaya DOKUNULMAZ — hata fırlar
    }

    private func backupIfExists() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.blooper-backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }

    private func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }
}
