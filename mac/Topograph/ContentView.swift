import SwiftUI
import TopographCore

/// Loads the library off the main thread. Each load opens the file, reads one
/// snapshot and closes it, so the app holds nothing open against the Python tools.
@MainActor
@Observable
final class MapModel {
    enum Phase {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase = Phase.loading
    private(set) var scene: TerrainScene?
    let controller = TerrainController()

    func load() {
        Task {
            do {
                scene = try await Task.detached(priority: .userInitiated) {
                    let items = try Library().mapItems()
                    return TerrainScene(items: items, field: DensityField(items: items))
                }.value
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func fail(_ message: String) { phase = .failed(message) }
}

struct ContentView: View {
    let model: MapModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.of(scheme)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("topograph").font(PlexMono.font(.semibold, size: 15)).foregroundStyle(theme.ink.color)
                Spacer()
                if let scene = model.scene {
                    Text("\(scene.items.count.formatted()) on the map")
                        .font(PlexMono.font(.regular, size: 11))
                        .foregroundStyle(theme.secondary.color)
                }
                ReadOnlyLamp(theme: theme)
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .frame(height: 38)
            Rectangle().fill(theme.ink.color).frame(height: 1)

            ZStack(alignment: .bottomTrailing) {
                TerrainView(scene: model.scene, controller: model.controller) { model.fail($0) }
                VStack(spacing: 4) {
                    Button("+", action: model.controller.zoomIn).accessibilityLabel("Zoom in")
                    Button("−", action: model.controller.zoomOut).accessibilityLabel("Zoom out")
                    Button("fit", action: model.controller.fit).accessibilityLabel("Show everything")
                }
                .buttonStyle(SquareKeyStyle(theme: theme))
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                status(theme)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(theme.ground.color)
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder
    private func status(_ theme: Theme) -> some View {
        switch model.phase {
        case .ready:
            EmptyView()
        case .loading:
            Message(text: "Reading the library…", theme: theme)
        case .failed(let text):
            Message(text: text, theme: theme)
        }
    }
}

private struct Message: View {
    let text: String
    let theme: Theme

    var body: some View {
        Text(text)
            .font(PlexMono.font(.regular, size: 12))
            .foregroundStyle(theme.ink.color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surface.color)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.ink.color, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A key that isn't pressed: the LED says the library is only ever read.
private struct ReadOnlyLamp: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(theme.ink.color).frame(width: 7, height: 7)
            Text("read-only").font(PlexMono.font(.medium, size: 11)).foregroundStyle(theme.ink.color)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(theme.surface.color)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
    }
}

private struct SquareKeyStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        Key(configuration: configuration, theme: theme)
    }

    private struct Key: View {
        let configuration: Configuration
        let theme: Theme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(PlexMono.font(.medium, size: 11))
                .foregroundStyle(theme.ink.color)
                .frame(width: 28, height: 28)
                .background(theme.surface.color)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(hovering ? theme.ink.color : theme.rule.color, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .offset(y: configuration.isPressed ? 1 : 0)
                .onHover { hovering = $0 }
        }
    }
}
