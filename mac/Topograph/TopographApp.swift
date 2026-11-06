import SwiftUI

@main
struct TopographApp: App {
    @State private var model = AppModel()

    init() {
        PlexMono.registerFonts()
    }

    var body: some Scene {
        Window("Topograph", id: "main") {
            ContentView(model: model)
                .onAppear { model.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Map") {
                Button("Zoom In") { model.controller.zoomIn() }.keyboardShortcut("=")
                Button("Zoom Out") { model.controller.zoomOut() }.keyboardShortcut("-")
                Button("Show Everything") { model.controller.fit() }.keyboardShortcut("0")
                Divider()
                Button("Reload Library") { model.load() }.keyboardShortcut("r")
            }
        }
    }
}
