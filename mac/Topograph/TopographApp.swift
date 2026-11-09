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
            // ⌘P plays the timeline, and there's nothing here to print.
            CommandGroup(replacing: .printItem) {}
            CommandMenu("Map") {
                Button("Zoom In") { model.zoomIn() }.keyboardShortcut("=")
                Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-")
                Button("Show Everything") { model.fit() }.keyboardShortcut("0")
                // The terrain, or on Palette, the wheel.
                Toggle("In 3D", isOn: Bindable(model).showsThreeD).keyboardShortcut("d")
                Divider()
                Button("Reload Library") { model.load() }.keyboardShortcut("r")
            }
        }
    }
}
