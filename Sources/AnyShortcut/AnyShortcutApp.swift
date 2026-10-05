import AnyShortcutCore
import SwiftUI

@main
struct AnyShortcutApp: App {
    @State private var model = AppModel(
        store: JSONStateStore.standard, client: ScriptingBridgeShortcutsClient(), supportsPlainText: false
    )

    var body: some Scene {
        Window("AnyShortcut", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 480)
        }
        .defaultSize(width: 820, height: 720)
    }
}
