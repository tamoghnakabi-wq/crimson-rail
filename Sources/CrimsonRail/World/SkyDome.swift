import Foundation
import SceneKit
import AppKit
import simd

/// Inside-out sphere that follows the camera.
///
/// It is deliberately *small* (10 m radius) and drawn first with depth reads and
/// writes off. That keeps it inside `fogStartDistance` — SceneKit's fog applies
/// to every fragment, so a genuinely distant sky dome would be fogged to a flat
/// wash and lose its stars — while still rendering behind all real geometry.
final class SkyDome {
    let node: SCNNode

    init(style: Style, seed: UInt64) {
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 36
        sphere.isGeodesic = false

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = SkyDome.makeImage(style: style, seed: seed)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        sphere.materials = [m]

        node = SCNNode(geometry: sphere)
        node.renderingOrder = -1000
        node.castsShadow = false
        node.name = "sky"
    }

    func update(cameraPosition: SIMD3<Float>) {
        node.simdPosition = cameraPosition
    }

    enum Style {
        /// Clear, moonlit, deep blue-black with a dense star field.
        case moonlitNight
        /// Overcast and lit orange from below by fires.
        case burningOvercast
        /// Heavy storm: near-black, fast cloud, occasional lightning wash.
        case storm
        /// Effectively no sky (interiors) — a flat, very dark vault.
        case blackVault
    }

    private static func makeImage(style: Style, seed: UInt64) -> CGImage {
        let w = 2048, h = 1024
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var rng = Rand(seed: seed)

        // Star positions drawn first into a sparse table so the per-pixel loop
        // stays cheap; a full noise pass per pixel would be far more expensive.
        var stars: [(x: Int, y: Int, b: Float, r: Float)] = []
        if case .moonlitNight = style {
            for _ in 0..<2600 {
                let sx = rng.int(0, w - 1)
                // Bias toward the upper hemisphere; v = 0 is the zenith.
                let sy = rng.int(0, Int(Float(h) * 0.62))
                // Sub-pixel radii: the dome is only 10 m across, so a star a few
                // texels wide subtends a huge angle and reads as falling snow.
                stars.append((sx, sy, rng.float(0.30, 1.0), rng.chance(0.05) ? 1.15 : 0.62))
            }
        }

        for py in 0..<h {
            // v: 0 at zenith, 1 at nadir.
            let v = Float(py) / Float(h - 1)
            let elevation = 1 - v * 2      // +1 up, -1 down
            for px in 0..<w {
                let u = Float(px) / Float(w - 1)
                var c: SIMD3<Float>

                switch style {
                case .moonlitNight:
                    let horizon = smoothstep(0.35, -0.10, elevation)
                    let zenith = SIMD3<Float>(0.012, 0.020, 0.045)
                    let horizonCol = SIMD3<Float>(0.055, 0.070, 0.115)
                    c = simd_mix(zenith, horizonCol, SIMD3(repeating: horizon))
                    // Thin cloud banding, so the sky is not a flat gradient.
                    let cloud = Noise.fbm(u * 8, v * 10, octaves: 4, period: 8, seed: seed &+ 3)
                    c += SIMD3(repeating: smoothstep(0.55, 0.85, cloud) * 0.035 * (1 - horizon * 0.5))
                    // The moon, and its halo.
                    let md = simd_length(SIMD2(angleWrap(u - 0.30) * 2.2, (v - 0.22) * 2.6))
                    c += SIMD3<Float>(0.55, 0.62, 0.78) * smoothstep(0.055, 0.030, md)
                    c += SIMD3<Float>(0.10, 0.13, 0.20) * smoothstep(0.34, 0.05, md)

                case .burningOvercast:
                    let horizon = smoothstep(0.45, -0.25, elevation)
                    let zenith = SIMD3<Float>(0.030, 0.026, 0.030)
                    let horizonCol = SIMD3<Float>(0.190, 0.075, 0.030)
                    c = simd_mix(zenith, horizonCol, SIMD3(repeating: horizon))
                    let cloud = Noise.fbm(u * 6, v * 7, octaves: 5, period: 6, seed: seed &+ 11)
                    // Underlit cloud bellies: the fires below are the light source.
                    c += SIMD3<Float>(0.16, 0.055, 0.018) * smoothstep(0.42, 0.80, cloud) * horizon
                    c *= 0.85 + cloud * 0.35

                case .storm:
                    let horizon = smoothstep(0.5, -0.3, elevation)
                    c = simd_mix(SIMD3(0.010, 0.012, 0.020), SIMD3(0.038, 0.042, 0.058),
                                 SIMD3(repeating: horizon))
                    let cloud = Noise.fbm(u * 5, v * 6, octaves: 5, period: 5, seed: seed &+ 7)
                    let cloud2 = Noise.ridged(u * 3, v * 4, octaves: 4, period: 3, seed: seed &+ 8)
                    c += SIMD3(repeating: smoothstep(0.5, 0.9, cloud) * 0.030)
                    c += SIMD3<Float>(0.05, 0.055, 0.08) * smoothstep(0.65, 0.95, cloud2) * 0.5

                case .blackVault:
                    c = SIMD3(repeating: 0.006 + smoothstep(0.6, -0.6, elevation) * 0.010)
                }

                let i = (py * w + px) * 4
                bytes[i + 0] = encode(c.x); bytes[i + 1] = encode(c.y); bytes[i + 2] = encode(c.z)
                bytes[i + 3] = 255
            }
        }

        // Stars, splatted after the gradient so they are not washed out by it.
        for s in stars {
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = s.x + dx, y = s.y + dy
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    let d = sqrt(Float(dx * dx + dy * dy))
                    let a = clamp01(1 - d / s.r) * s.b
                    guard a > 0.01 else { continue }
                    let i = (y * w + x) * 4
                    for ch in 0..<3 {
                        let existing = Float(bytes[i + ch]) / 255
                        bytes[i + ch] = UInt8(clamp01(existing + a) * 255)
                    }
                }
            }
        }

        var data = bytes
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private static func encode(_ linear: Float) -> UInt8 {
        let c = clamp01(linear)
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8(clamp01(s) * 255)
    }

    /// Shortest wrapped distance on a 0..1 circular axis.
    private static func angleWrap(_ x: Float) -> Float {
        var d = x - floor(x)
        if d > 0.5 { d -= 1 }
        return d
    }
}
