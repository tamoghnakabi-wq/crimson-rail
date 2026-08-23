import Foundation
import AppKit
import CoreGraphics

/// Draws the app icon and writes an `.icns`.
///
/// Like everything else the game ships, the icon is generated rather than
/// authored: two rails converging on a vanishing point, framed by a reticle.
extension Harness {
    static func icon(_ args: Args) -> Int32 {
        let path = args.string("--icon") ?? "AppIcon.icns"
        // The set macOS actually asks for, from the Finder list view up to Retina
        // Get Info. Anything missing falls back to a scaled neighbour and looks it.
        let entries: [(type: String, size: Int)] = [
            ("icp4", 16), ("icp5", 32), ("icp6", 64),
            ("ic07", 128), ("ic08", 256), ("ic09", 512),
            ("ic10", 1024), ("ic11", 32), ("ic12", 64),
            ("ic13", 256), ("ic14", 512)
        ]

        var payload = Data()
        for e in entries {
            guard let png = pngData(size: e.size) else { continue }
            payload.append(contentsOf: Array(e.type.utf8))
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(png.count + 8).bigEndian) { Array($0) })
            payload.append(png)
        }
        var icns = Data()
        icns.append(contentsOf: Array("icns".utf8))
        icns.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count + 8).bigEndian) { Array($0) })
        icns.append(payload)

        do {
            try icns.write(to: URL(fileURLWithPath: path))
            out("wrote \(path) (\(icns.count) bytes, \(entries.count) sizes)")
            return 0
        } catch {
            out("failed to write \(path): \(error)")
            return 1
        }
    }

    private static func pngData(size: Int) -> Data? {
        guard let image = draw(size: size) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(size n: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = CGFloat(n)
        ctx.setShouldAntialias(true)

        // Rounded-square plate, macOS-style proportions.
        let inset = s * 0.055
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let plate = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
        ctx.saveGState()
        ctx.addPath(plate)
        ctx.clip()

        // Vertical gradient from near-black to a deep blood red at the base.
        let colors = [
            CGColor(red: 0.055, green: 0.050, blue: 0.058, alpha: 1),
            CGColor(red: 0.085, green: 0.045, blue: 0.048, alpha: 1),
            CGColor(red: 0.22, green: 0.035, blue: 0.030, alpha: 1)
        ] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        }

        // Two rails converging on a vanishing point above centre.
        let vp = CGPoint(x: s * 0.5, y: s * 0.60)
        ctx.setLineCap(.round)
        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.move(to: CGPoint(x: s * 0.5 + side * s * 0.40, y: s * 0.16))
            ctx.addLine(to: vp)
            ctx.setStrokeColor(CGColor(red: 0.62, green: 0.13, blue: 0.10, alpha: 0.95))
            ctx.setLineWidth(max(s * 0.028, 1))
            ctx.strokePath()
        }
        // Sleepers, spaced so they compress toward the vanishing point.
        for i in 0..<7 {
            let t = CGFloat(i) / 7
            let y = s * 0.16 + (vp.y - s * 0.16) * (t * t)
            let halfWidth = s * 0.40 * (1 - t * t) * 0.92
            ctx.move(to: CGPoint(x: s * 0.5 - halfWidth, y: y))
            ctx.addLine(to: CGPoint(x: s * 0.5 + halfWidth, y: y))
            ctx.setStrokeColor(CGColor(red: 0.55, green: 0.12, blue: 0.09, alpha: 0.55 * (1 - t * 0.7)))
            ctx.setLineWidth(max(s * 0.018 * (1 - t * 0.6), 0.6))
            ctx.strokePath()
        }

        // Reticle: ring plus four ticks, in bone white so it reads at 16 px.
        let r = s * 0.255
        ctx.setStrokeColor(CGColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 0.96))
        ctx.setLineWidth(max(s * 0.036, 1.2))
        ctx.addEllipse(in: CGRect(x: s * 0.5 - r, y: s * 0.5 - r, width: r * 2, height: r * 2))
        ctx.strokePath()

        for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 2) {
            let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
            ctx.move(to: CGPoint(x: s * 0.5 + dx * r * 0.55, y: s * 0.5 + dy * r * 0.55))
            ctx.addLine(to: CGPoint(x: s * 0.5 + dx * r * 1.42, y: s * 0.5 + dy * r * 1.42))
        }
        ctx.setLineWidth(max(s * 0.034, 1.2))
        ctx.strokePath()

        // Centre pip.
        ctx.setFillColor(CGColor(red: 0.88, green: 0.16, blue: 0.12, alpha: 1))
        let pip = s * 0.038
        ctx.fillEllipse(in: CGRect(x: s * 0.5 - pip, y: s * 0.5 - pip, width: pip * 2, height: pip * 2))

        ctx.restoreGState()

        // A hairline highlight along the top edge, which is what makes a flat
        // plate look like a physical object in the Dock.
        ctx.addPath(plate)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
        ctx.setLineWidth(max(s * 0.008, 0.5))
        ctx.strokePath()

        return ctx.makeImage()
    }
}
