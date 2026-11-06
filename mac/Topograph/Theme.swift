import AppKit
import CoreText
import SwiftUI
import simd

/// The design language's one ink and one ground; dark mode inverts. Values are the
/// viewer's, from viewer/style.css.
struct Theme: Sendable {
    let ground: RGB
    let surface: RGB
    let ink: RGB
    let secondary: RGB
    let rule: RGB
    let hair: RGB

    static let light = Theme(ground: RGB(0xe9e9e6), surface: RGB(0xf4f4f1), ink: RGB(0x111111),
                             secondary: RGB(0x5a5a54), rule: RGB(0xb4b4ae), hair: RGB(0xd3d3cd))
    static let dark = Theme(ground: RGB(0x101010), surface: RGB(0x181817), ink: RGB(0xe9e9e4),
                            secondary: RGB(0x9b9b94), rule: RGB(0x3c3c39), hair: RGB(0x252523))

    static func of(_ scheme: ColorScheme) -> Theme { scheme == .dark ? .dark : .light }
}

struct RGB: Sendable {
    let red, green, blue: Float

    init(_ hex: UInt32) {
        red = Float((hex >> 16) & 0xff) / 255
        green = Float((hex >> 8) & 0xff) / 255
        blue = Float(hex & 0xff) / 255
    }

    var simd: SIMD4<Float> { SIMD4(red, green, blue, 1) }
    var color: Color { Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue)) }
}

/// IBM Plex Mono, bundled with the app.
enum PlexMono {
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ weight: Font.Weight, size: CGFloat) -> Font {
        let name = switch weight {
        case .semibold: "IBMPlexMono-SemiBold"
        case .medium: "IBMPlexMono-Medium"
        default: "IBMPlexMono-Regular"
        }
        return .custom(name, fixedSize: size)
    }
}
