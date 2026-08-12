import Foundation

enum StatuslineError: Error, Equatable {
    case unparsableSettings, unparsableConfig, alreadyContainsBlooper, templateMissing
}

struct StatuslineInstaller {
    let settingsURL: URL
    let configURL: URL
    let binDir: URL
    let templateURL: URL

    static let fragmentCommand = "\"$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh\""
    static let wrapperCommand  = "\"$HOME/Library/Application Support/Blooper/bin/blooper-statusline.sh\""
    private static let marker = "BLOOPER-STATUSLINE-WRAPPER"

    private var wrapperFile: URL { binDir.appendingPathComponent("blooper-statusline.sh") }

    private enum Kind { case none, fragment, wrapper, foreign }

    private func classify(_ root: [String: Any]) -> Kind {
        guard let sl = root["statusLine"] as? [String: Any],
              let cmd = (sl["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .none }
        // Tam eşitlik ŞART: yolu içeren-ama-eşit-olmayan komut kullanıcının kendi zinciridir
        if cmd == Self.fragmentCommand { return .fragment }
        if cmd == Self.wrapperCommand { return .wrapper }
        return .foreign
    }

    func isInstalled() -> Bool {
        guard let root = try? readJSON(settingsURL) else { return false }
        switch classify(root) { case .fragment, .wrapper: return true; default: return false }
    }

    @discardableResult
    func install() throws -> String? {
        var root = try readJSONOrEmpty(settingsURL, error: .unparsableSettings)
        switch classify(root) {
        case .fragment: return nil                       // idempotent
        case .wrapper:
            try regenerateWrapperIfVersionChanged()
            return nil
        case .none:
            root["statusLine"] = ["type": "command", "command": Self.fragmentCommand, "refreshInterval": 30]
            try backupAndWrite(root)
            return nil
        case .foreign:
            let original = root["statusLine"] as! [String: Any]
            let cmd = (original["command"] as? String) ?? ""
            if foreignScriptContainsMarker(cmd) { throw StatuslineError.alreadyContainsBlooper }
            try saveOriginalToConfig(original)
            try generateWrapper(original: cmd)
            var sl = original
            sl["command"] = Self.wrapperCommand
            root["statusLine"] = sl                      // diğer anahtarlar settings'te korunur
            try backupAndWrite(root)
            return nil
        }
    }

    @discardableResult
    func uninstall() throws -> String? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        var root = try readJSONOrEmpty(settingsURL, error: .unparsableSettings)
        switch classify(root) {
        case .none: return nil
        case .fragment:
            root.removeValue(forKey: "statusLine")
            try backupAndWrite(root)
            return nil
        case .wrapper:
            defer { try? FileManager.default.removeItem(at: wrapperFile) }
            if let original = try takeOriginalFromConfig() {
                root["statusLine"] = original
                try backupAndWrite(root)
                return nil
            }
            root.removeValue(forKey: "statusLine")       // fallback: fragment-dalı davranışı
            try backupAndWrite(root)
            return "Orijinal statusline kaydı bulunamadı; gerekirse settings.json.blooper-backup dosyasından geri alabilirsiniz."
        case .foreign:
            if (try? takeOriginalFromConfig(peek: true)) ?? nil != nil {
                return "Statusline başka bir araç tarafından değiştirilmiş; Blooper dokunmuyor. Orijinal kaydınız config.json içinde 'original_statusline' olarak duruyor."
            }
            return nil                                    // idempotent: bizden iz yok
        }
    }

    // MARK: - iç yardımcılar

    private func regenerateWrapperIfVersionChanged() throws {
        let current = (try? String(contentsOf: wrapperFile, encoding: .utf8)) ?? ""
        let template = try templateText()
        let versionLine = template.split(separator: "\n").first { $0.contains(Self.marker) }.map(String.init) ?? ""
        guard !versionLine.isEmpty, !current.contains(versionLine) else { return }
        // sürüm farklı: config'teki orijinalle güncel şablondan yeniden üret
        if let original = try takeOriginalFromConfig(peek: true),
           let cmd = original["command"] as? String {
            try generateWrapper(original: cmd)
        }
    }

    private func foreignScriptContainsMarker(_ command: String) -> Bool {
        // best-effort: interpreter token'larını soy, tırnakları çöz, $HOME/~ genişlet
        var tokens = command.split(separator: " ").map(String.init)
        while let first = tokens.first, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(first) {
            tokens.removeFirst()
        }
        guard var path = tokens.first else { return false }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        path = path.replacingOccurrences(of: "$HOME", with: home)
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard FileManager.default.isReadableFile(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return content.contains(Self.marker)
    }

    private func generateWrapper(original: String) throws {
        let template = try templateText()
        // Tek güvenli kaçış: ' → '\''  (bash tek-tırnaklı string'de tek metakarakter ' işaretidir)
        let escaped = original.replacingOccurrences(of: "'", with: "'\\''")
        let content = template.replacingOccurrences(of: "__BLOOPER_ORIGINAL__", with: escaped)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try content.write(to: wrapperFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperFile.path)
    }

    private func templateText() throws -> String {
        guard let text = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw StatuslineError.templateMissing
        }
        return text
    }

    private func saveOriginalToConfig(_ original: [String: Any]) throws {
        var cfg = try readJSONOrEmpty(configURL, error: .unparsableConfig)   // RMW: diğer anahtarlar korunur
        cfg["original_statusline"] = original
        try writeJSON(cfg, to: configURL)
    }

    private func takeOriginalFromConfig(peek: Bool = false) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        guard var cfg = try? readJSON(configURL) else { return nil }         // bozuk config = kayıt yok say
        guard let original = cfg["original_statusline"] as? [String: Any] else { return nil }
        if !peek {
            cfg.removeValue(forKey: "original_statusline")
            try writeJSON(cfg, to: configURL)
        }
        return original
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StatuslineError.unparsableSettings
        }
        return obj
    }

    private func readJSONOrEmpty(_ url: URL, error: StatuslineError) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error }
        return obj
    }

    private func backupAndWrite(_ root: [String: Any]) throws {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.blooper-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        try writeJSON(root, to: settingsURL)
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
