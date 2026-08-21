import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF)/255,
            green: CGFloat((v >> 8) & 0xFF)/255,
            blue: CGFloat(v & 0xFF)/255, alpha: a)
}

/// Apple-style continuous rounded rect (squircle-ish) via relative bezier.
func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 0.5523    // circular-arc control offset (was 0.128 — pinched the corners)
    let x = r.minX, y = r.minY, w = r.width, h = r.height, c = radius
    p.move(to: CGPoint(x: x + c, y: y))
    p.addLine(to: CGPoint(x: x + w - c, y: y))
    p.addCurve(to: CGPoint(x: x + w, y: y + c),
               control1: CGPoint(x: x + w - c*k, y: y),
               control2: CGPoint(x: x + w, y: y + c*k))
    p.addLine(to: CGPoint(x: x + w, y: y + h - c))
    p.addCurve(to: CGPoint(x: x + w - c, y: y + h),
               control1: CGPoint(x: x + w, y: y + h - c*k),
               control2: CGPoint(x: x + w - c*k, y: y + h))
    p.addLine(to: CGPoint(x: x + c, y: y + h))
    p.addCurve(to: CGPoint(x: x, y: y + h - c),
               control1: CGPoint(x: x + c*k, y: y + h),
               control2: CGPoint(x: x, y: y + h - c*k))
    p.addLine(to: CGPoint(x: x, y: y + c))
    p.addCurve(to: CGPoint(x: x + c, y: y),
               control1: CGPoint(x: x, y: y + c*k),
               control2: CGPoint(x: x + c*k, y: y))
    p.closeSubpath()
    return p
}

func drawIcon(size S: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS 26 masks and shapes the icon itself, so the artwork must be FULL BLEED.
    // Drawing our own rounded tile produces a tile-inside-a-tile.
    let art = CGRect(x: 0, y: 0, width: S, height: S)

    // ---- graphite body, edge to edge
    let g = CGGradient(colorsSpace: cs,
                       colors: [rgb(0x43434C), rgb(0x232329), rgb(0x141418)] as CFArray,
                       locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: art.maxY),
                           end: CGPoint(x: 0, y: art.minY), options: [])

    // ---- the two minds: overlapping lenses, additive so the overlap glows
    let cy = art.midY
    let rr = art.width * 0.205
    let dx = art.width * 0.113
    ctx.setBlendMode(.plusLighter)

    let vG = CGGradient(colorsSpace: cs,
                        colors: [rgb(0x9C86F5), rgb(0x5F40CC)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: art.midX - dx - rr, y: cy - rr, width: rr*2, height: rr*2))
    ctx.clip()
    ctx.drawLinearGradient(vG, start: CGPoint(x: art.midX - dx, y: cy + rr),
                           end: CGPoint(x: art.midX - dx, y: cy - rr), options: [])
    ctx.restoreGState()

    let oG = CGGradient(colorsSpace: cs,
                        colors: [rgb(0xF0A45C), rgb(0xC96A1E)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: art.midX + dx - rr, y: cy - rr, width: rr*2, height: rr*2))
    ctx.clip()
    ctx.drawLinearGradient(oG, start: CGPoint(x: art.midX + dx, y: cy + rr),
                           end: CGPoint(x: art.midX + dx, y: cy - rr), options: [])
    ctx.restoreGState()
    ctx.setBlendMode(.normal)

    // ---- soft top-light so the flat gradient reads as a surface
    ctx.saveGState()
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0.0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: art.maxY),
                           end: CGPoint(x: 0, y: art.midY), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let d = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

@main
struct R {
    static func main() {
        let out = CommandLine.arguments[1]
        for s in [16, 32, 64, 128, 256, 512, 1024] {
            write(drawIcon(size: CGFloat(s)), "\(out)/icon_\(s).png")
        }
        print("rendered")
    }
}
