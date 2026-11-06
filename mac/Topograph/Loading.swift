import SwiftUI

/// Says something is on its way, with a blinking lamp. Waits a moment before showing, so
/// quick work doesn't flash it.
struct LoadingNote: View {
    let text: String
    let theme: Theme
    /// Seconds behind other notes' lamps, so a column of them blinks in a wave.
    var delay = 0.0
    @State private var shown = false

    private static let blink = 0.4

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: delay), by: Self.blink)) { context in
                let on = Int((context.date.timeIntervalSinceReferenceDate - delay) / Self.blink) % 2 == 0
                Rectangle()
                    .fill(on ? theme.ink.color : Color.clear)
                    .overlay(Rectangle().strokeBorder(theme.ink.color, lineWidth: 1))
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(PlexMono.font(.regular, size: 11))
                .foregroundStyle(theme.secondary.color)
        }
        .opacity(shown ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            shown = true
        }
    }
}
