import XCTest
@testable import Blooper

final class StatuslineInstallerTests: XCTestCase {
    var dir: URL!
    var installer: StatuslineInstaller!
    var settings: URL { dir.appendingPathComponent("settings.json") }
    var config: URL { dir.appendingPathComponent("config.json") }
    var binDir: URL { dir.appendingPathComponent("bin") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Şablon repo'dan okunur: test, gerçek üretim şablonunu kullanır
        let template = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/scripts/statusline-wrapper-template.sh")
        installer = StatuslineInstaller(settingsURL: settings, configURL: config, binDir: binDir, templateURL: template)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ url: URL, _ json: String) throws { try json.write(to: url, atomically: true, encoding: .utf8) }
    private func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private func statusLine() throws -> [String: Any]? { try readJSON(settings)["statusLine"] as? [String: Any] }

    func testInstallIntoMissingStatusline() throws {
        try write(settings, "{}")
        XCTAssertNil(try installer.install())
        let sl = try XCTUnwrap(try statusLine())
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertTrue((sl["command"] as? String ?? "").contains("statusline-fragment.sh"))
        XCTAssertEqual(sl["refreshInterval"] as? Int, 30)
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallWrapsForeignAndUninstallRestoresExactly() throws {
        let original: [String: Any] = ["type": "command", "command": "my-status --flag",
                                       "padding": 0, "refreshInterval": 5, "customKey": "x"]
        try write(settings, String(data: JSONSerialization.data(withJSONObject: ["statusLine": original]), encoding: .utf8)!)
        try write(config, #"{"model":"claude-haiku-4-5","notifications":true}"#)
        XCTAssertNil(try installer.install())
        let sl = try XCTUnwrap(try statusLine())
        XCTAssertTrue((sl["command"] as? String ?? "").contains("blooper-statusline.sh"))
        XCTAssertEqual(sl["padding"] as? Int, 0, "diğer anahtarlar settings'te korunur")
        let wrapper = try String(contentsOf: binDir.appendingPathComponent("blooper-statusline.sh"), encoding: .utf8)
        XCTAssertTrue(wrapper.contains("my-status --flag"))
        XCTAssertFalse(wrapper.contains("__BLOOPER_ORIGINAL__"))
        let cfg = try readJSON(config)
        XCTAssertEqual(cfg["model"] as? String, "claude-haiku-4-5")
        let saved = try XCTUnwrap(cfg["original_statusline"] as? [String: Any])
        XCTAssertEqual(saved["customKey"] as? String, "x")
        XCTAssertNil(try installer.uninstall())
        let restored = try XCTUnwrap(try statusLine())
        XCTAssertEqual(restored["command"] as? String, "my-status --flag")
        XCTAssertEqual(restored["refreshInterval"] as? Int, 5)
        XCTAssertEqual(restored["customKey"] as? String, "x")
        XCTAssertNil((try readJSON(config))["original_statusline"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDir.appendingPathComponent("blooper-statusline.sh").path))
    }

    func testSingleQuoteOriginalEscapedCorrectly() throws {
        let cmd = "echo 'hi there'"
        try write(settings, String(data: JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": cmd]]), encoding: .utf8)!)
        try installer.install()
        let wrapper = try String(contentsOf: binDir.appendingPathComponent("blooper-statusline.sh"), encoding: .utf8)
        XCTAssertTrue(wrapper.contains("echo '\\''hi there'\\''"), "tek tırnaklar '\\'' olarak kaçmalı")
        XCTAssertFalse(wrapper.contains("__BLOOPER_ORIGINAL__"))
    }

    func testEmbeddedFragmentInForeignPipelineIsForeign() throws {
        let cmd = "my-status | tee /dev/null && \"$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh\""
        try write(settings, String(data: JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": cmd]]), encoding: .utf8)!)
        XCTAssertFalse(installer.isInstalled(), "yolu içeren ama eşit olmayan komut yabancıdır")
        _ = try? installer.uninstall()
        XCTAssertEqual((try statusLine())?["command"] as? String, cmd)
    }

    func testInstallIsIdempotent() throws {
        try write(settings, "{}")
        try installer.install()
        try installer.install()
        XCTAssertTrue((try statusLine())?["command"] as? String != nil)
    }

    func testDoubleWrapRejectedViaFileScan() throws {
        // yabancı script bizim marker'ı içeriyor (Blooper'ı sarmış) → kurulum reddedilir
        let foreign = binDir.appendingPathComponent("their-status.sh")
        try "#!/bin/bash\n# BLOOPER-STATUSLINE-WRAPPER v1 kopyası\necho hi\n".write(to: foreign, atomically: true, encoding: .utf8)
        try write(settings, String(data: JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": foreign.path]]), encoding: .utf8)!)
        XCTAssertThrowsError(try installer.install()) {
            XCTAssertEqual($0 as? StatuslineError, .alreadyContainsBlooper)
        }
    }

    func testUninstallFragmentRemovesKey() throws {
        try write(settings, "{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertNil(try statusLine())
        XCTAssertNil((try readJSON(settings))["statusLine"])
    }

    func testUninstallWrapperMissingOriginalFallsBack() throws {
        try write(settings, #"{"statusLine":{"type":"command","command":"my-status"}}"#)
        try installer.install()
        try write(config, "{}")   // original_statusline kaydını elle sil
        let msg = try installer.uninstall()
        XCTAssertNotNil(msg, "kayıp kayıtta kullanıcıya mesaj dönmeli")
        XCTAssertNil(try statusLine())
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDir.appendingPathComponent("blooper-statusline.sh").path))
    }

    func testUninstallIsIdempotent() throws {
        try write(settings, "{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertNoThrow(try installer.uninstall())
    }

    func testUnparsableSettingsUntouched() throws {
        try write(settings, "{broken")
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{broken")
    }

    func testForeignChangeAfterInstallInformsOnRemove() throws {
        try write(settings, #"{"statusLine":{"type":"command","command":"my-status"}}"#)
        try installer.install()
        // başka araç statusline'ı değiştirdi
        try write(settings, #"{"statusLine":{"type":"command","command":"other-tool"}}"#)
        let msg = try installer.uninstall()
        XCTAssertNotNil(msg, "yabancı + config'te sıkışmış kayıt → açıklayıcı mesaj")
        XCTAssertEqual((try statusLine())?["command"] as? String, "other-tool", "yabancıya dokunulmaz")
    }

    func testInstallCreatesBackup() throws {
        try write(settings, #"{"statusLine":{"type":"command","command":"my-status"}}"#)
        try installer.install()
        let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.json.blooper-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testMarkerVersionChangeRegeneratesWrapper() throws {
        try write(settings, #"{"statusLine":{"type":"command","command":"my-status"}}"#)
        try installer.install()
        // eski sürümlü wrapper simüle et: marker satırını v0'a boz
        let wrapper = binDir.appendingPathComponent("blooper-statusline.sh")
        let old = try String(contentsOf: wrapper, encoding: .utf8)
            .replacingOccurrences(of: "BLOOPER-STATUSLINE-WRAPPER v1", with: "BLOOPER-STATUSLINE-WRAPPER v0")
        try old.write(to: wrapper, atomically: true, encoding: .utf8)
        try installer.install()   // sürüm farkı → güncel şablonla yeniden üretim
        let regenerated = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertTrue(regenerated.contains("BLOOPER-STATUSLINE-WRAPPER v1"))
        XCTAssertTrue(regenerated.contains("my-status"), "orijinal config'ten korunarak yeniden gömülür")
    }
}
