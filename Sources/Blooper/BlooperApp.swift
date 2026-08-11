import SwiftUI

@main
struct BlooperApp: App {
    var body: some Scene {
        MenuBarExtra("Blooper", systemImage: "text.badge.xmark") {
            Text("Blooper")
        }
        .menuBarExtraStyle(.window)
    }
}
