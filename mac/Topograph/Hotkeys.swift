import SwiftUI

/// Where a shortcut's label goes.
enum HotkeyPlacement {
    /// Under the key's right end.
    case below
    /// Under its left end.
    case belowLeft
    /// To its left, for keys stacked too closely to hang a label below.
    case beside

    fileprivate var alignment: Alignment {
        switch self {
        case .below: .bottomTrailing
        case .belowLeft: .bottomLeading
        case .beside: .trailing
        }
    }
}

/// A key's keyboard shortcut, with a small label that shows while you hold ⌘, or once
/// you've rested on the key for a second. Pass no `key` for a shortcut set elsewhere,
/// such as in the Map menu.
private struct Hotkey: ViewModifier {
    let label: String
    let key: KeyEquivalent?
    let modifiers: EventModifiers
    let placement: HotkeyPlacement
    let model: AppModel
    let theme: Theme
    @State private var hovering = false
    @State private var rested = false

    private var showing: Bool { rested || model.commandHeld }

    func body(content: Content) -> some View {
        shortcut(content)
            .onHover { hovering = $0 }
            .task(id: hovering) {
                rested = false
                guard hovering else { return }
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { rested = true }
            }
            .overlay(alignment: placement.alignment) {
                if showing {
                    Text(label.uppercased())
                        .font(PlexMono.font(.medium, size: 10))
                        .foregroundStyle(theme.ground.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .frame(height: 13)
                        .background(theme.ink.color, in: Rectangle())
                        // A square key is 28 wide, and the label stops just short of its left edge.
                        .offset(x: placement == .beside ? -31 : 0, y: placement == .beside ? 0 : 8)
                        .allowsHitTesting(false)
                }
            }
            // So the next key along doesn't cover the label.
            .zIndex(showing ? 1 : 0)
    }

    @ViewBuilder
    private func shortcut(_ content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

extension View {
    func hotkey(_ label: String, key: KeyEquivalent? = nil, modifiers: EventModifiers = .command, placement: HotkeyPlacement = .below,
                model: AppModel, theme: Theme) -> some View {
        modifier(Hotkey(label: label, key: key, modifiers: modifiers, placement: placement, model: model, theme: theme))
    }
}
