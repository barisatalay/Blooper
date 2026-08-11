import XCTest
@testable import Blooper

final class HookInstallerTests: XCTestCase {
    var dir: URL!
    var installer: HookInstaller!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = HookInstaller(settingsURL: dir.appendingPathComponent("settings.json"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ json: String) throws { try json.write(to: installer.settingsURL, atomically: true, encoding: .utf8) }
    private func readJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: installer.settingsURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func promptHooks(_ root: [String: Any]) -> [[String: Any]] {
        ((root["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]]) ?? []
    }

    func testInstallIntoMissingFileCreatesStructure() throws {
        try installer.install()
        let entries = promptHooks(try readJSON())
        XCTAssertEqual(entries.count, 1)
        let cmd = ((entries[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        XCTAssertTrue(cmd.contains("Blooper/bin/hook.sh"))
        XCTAssertTrue(cmd.contains("\"$HOME/"), "boşluklu yol tırnaklı olmalı")
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallPreservesForeignHooksAndKeys() throws {
        try write(#"{"model":"opus","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"other-tool"}]}],"Stop":[{"hooks":[{"type":"command","command":"stop-tool"}]}]}}"#)
        try installer.install()
        let root = try readJSON()
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual(promptHooks(root).count, 2)
        XCTAssertNotNil((root["hooks"] as? [String: Any])?["Stop"])
    }

    func testInstallIsIdempotent() throws {
        try installer.install()
        try installer.install()
        XCTAssertEqual(promptHooks(try readJSON()).count, 1)
    }

    func testUninstallRemovesOnlyOurEntry() throws {
        try write(#"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"other-tool"}]}]}}"#)
        try installer.install()
        try installer.uninstall()
        let entries = promptHooks(try readJSON())
        XCTAssertEqual(entries.count, 1)
        let cmd = ((entries[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        XCTAssertEqual(cmd, "other-tool")
        XCTAssertFalse(installer.isInstalled())
    }

    func testUnparsableSettingsThrowsAndDoesNotTouchFile() throws {
        try write("{broken json")
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try String(contentsOf: installer.settingsURL, encoding: .utf8), "{broken json")
    }

    func testInstallCreatesBackup() throws {
        try write(#"{"hooks":{}}"#)
        try installer.install()
        let backup = installer.settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.blooper-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
}
