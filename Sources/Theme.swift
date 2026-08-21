import SwiftUI
import AppKit

func hx(_ v: UInt32, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: Double((v >> 16) & 0xFF) / 255,
            green:   Double((v >>  8) & 0xFF) / 255,
            blue:    Double( v        & 0xFF) / 255,
            alpha:   a)
}
func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

enum T {
    static let label   = dyn(hx(0x1D1D1F), hx(0xF5F5F7))
    static let label2  = dyn(hx(0x5E5E63), hx(0xA8A8AE))
    static let label3  = dyn(hx(0x8A8A8F), hx(0x8A8A8F))
    static let hair    = dyn(hx(0x000000, 0.10), hx(0xFFFFFF, 0.13))
    static let surface = dyn(hx(0xFFFFFF, 0.85), hx(0x2C2C2E, 0.62))
    static let sunken  = dyn(hx(0x000000, 0.045), hx(0x000000, 0.22))
    static let apple   = dyn(hx(0x5B3FB8), hx(0xB4A5FF))
    static let qwen    = dyn(hx(0x9A3F0C), hx(0xF5A05A))
    static let ready   = dyn(hx(0x1D7F3C), hx(0x30D158))
    static let down    = dyn(hx(0x8A8A8F), hx(0x8A8A8F))
    // Screen capability gets NO new hue — it borrows the accent, per the
    // design system's "colour has exactly one job" principle.
    static let warn    = dyn(hx(0x8A5A00), hx(0xFFD426))

    // MARK: Depth
    //
    // Everything below is LUMINANCE ONLY — no new hues. Colour still has
    // exactly one job (naming which model answered); depth is carried by
    // tone, glass, and shadow instead.

    /// Light falling from above onto the window backdrop.
    static let washTop   = dyn(hx(0xFFFFFF, 0.42), hx(0xFFFFFF, 0.055))
    /// The backdrop settling into shadow at the foot of the window.
    static let washFoot  = dyn(hx(0x1B1B20, 0.075), hx(0x000000, 0.34))
    /// A single soft key light, up and to the left.
    static let keyLight  = dyn(hx(0xFFFFFF, 0.55), hx(0xFFFFFF, 0.075))

    /// The transcript reads as a page recessed BELOW the chrome.
    static let canvasTop = dyn(hx(0x000000, 0.035), hx(0x000000, 0.20))
    static let canvasBot = dyn(hx(0x000000, 0.070), hx(0x000000, 0.30))
    /// Inner shadow cast by the chrome down onto that page.
    static let inset     = dyn(hx(0x000000, 0.085), hx(0x000000, 0.34))

    /// Chrome plate — tonally ABOVE the page, the way a toolbar sits proud.
    static let chrome    = dyn(hx(0xFFFFFF, 0.50), hx(0xFFFFFF, 0.055))
    /// The bright top lip every raised surface catches.
    static let lip       = dyn(hx(0xFFFFFF, 0.90), hx(0xFFFFFF, 0.16))
    /// Cast shadows. Two weights: chrome floating over the page, and cards.
    static let castHard  = dyn(hx(0x000000, 0.22), hx(0x000000, 0.55))
    static let castSoft  = dyn(hx(0x000000, 0.11), hx(0x000000, 0.38))
}

enum AccentInk {
    static var onAccent: Color {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .white
        func lin(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        let L = 0.2126 * lin(c.redComponent)
              + 0.7152 * lin(c.greenComponent)
              + 0.0722 * lin(c.blueComponent)
        return L > 0.42 ? Color(nsColor: NSColor(white: 0.10, alpha: 1)) : .white
    }
}

@MainActor
final class AccentWatch: ObservableObject {
    @Published var tick = 0
    private var obs: NSObjectProtocol?
    init() {
        obs = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick += 1 }
            }
    }
}

enum S {
    static let measure        : CGFloat = 640
    static let trafficInset   : CGFloat = 78
    static let headerHeight   : CGFloat = 52
    static let gutter         : CGFloat = 32
    static let transcriptH    : CGFloat = 24
    static let transcriptV    : CGFloat = 20
    static let rowSpacing     : CGFloat = 18
    static let pairSpacing    : CGFloat = 12
    static let mdBlock        : CGFloat = 8
    static let inputH         : CGFloat = 14
    static let inputV         : CGFloat = 10
    static let bubbleH        : CGFloat = 13
    static let bubbleV        : CGFloat = 9
    static let badgeH         : CGFloat = 7
    static let badgeV         : CGFloat = 3
    static let thinkingHeight : CGFloat = 18
    /// The hue rail running down an assistant answer beside its glyph.
    static let spine          : CGFloat = 2
    /// How far content fades out beneath the header / above the composer.
    static let edgeFade       : CGFloat = 26
    static let bulletCol      : CGFloat = 11
}

enum R {
    static let inline : CGFloat = 5
    static let plate  : CGFloat = 6
    static let code   : CGFloat = 8
    static let chip   : CGFloat = 10
    static let drop   : CGFloat = 12
    static let card   : CGFloat = 12
    static let bubble : CGFloat = 16
    static let field  : CGFloat = 18
}

enum M {
    static let rise     = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let verdict  = Animation.snappy(duration: 0.26, extraBounce: 0.03)
    static let hover    = Animation.easeOut(duration: 0.12)
    static let press    = Animation.spring(response: 0.22, dampingFraction: 0.70)
    static let send     = Animation.spring(response: 0.26, dampingFraction: 0.80)
    static let focus    = Animation.easeOut(duration: 0.15)
    static let scroll   = Animation.easeOut(duration: 0.18)
    static let hairline = Animation.easeOut(duration: 0.20)
    static let numeric  = Animation.easeOut(duration: 0.20)
    static let drop     = Animation.spring(response: 0.30, dampingFraction: 0.85)
    static let jump     = Animation.spring(response: 0.30, dampingFraction: 0.80)
}
