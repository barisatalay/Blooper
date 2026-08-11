import Foundation
import UserNotifications

struct Notifier {
    // Bundle dışı süreçte (swift run) UNUserNotificationCenter crash eder; xctest'te ise
    // bundleIdentifier DOLU gelir ("com.apple.dt.xctest.tool") — XCTest yüklü mü diye bakılır
    // (test sürecinde NSClassFromString non-nil; app sürecinde XCTest linkli değil → nil)
    private static var hasBundle: Bool {
        Bundle.main.bundleIdentifier != nil && NSClassFromString("XCTestCase") == nil
    }

    static var notificationsEnabled: Bool {
        guard let data = try? Data(contentsOf: BlooperEnv.configFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flag = obj["notifications"] as? Bool else { return true }
        return flag
    }

    static func setNotificationsEnabled(_ on: Bool) {
        var obj = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: BlooperEnv.configFile)) ?? Data()) as? [String: Any]) ?? [:]
        obj["notifications"] = on
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: BlooperEnv.configFile, options: .atomic)
        }
    }

    static func notifyIfEnabled(_ fresh: [Mistake]) {
        guard hasBundle, notificationsEnabled, let first = fresh.first else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return } // izin yoksa sessiz: menübar sayacı birincil sinyal
            let content = UNMutableNotificationContent()
            content.title = "\(first.wrong) → \(first.right)"
            content.body = fresh.count > 1 ? "\(first.rule) (+\(fresh.count - 1) more)" : first.rule
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
