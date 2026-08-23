import Foundation
import SceneKit
import AppKit
import simd

/// Builds and caches `SCNMaterial`s from procedural textures.
///
/// Two SceneKit defaults bite here and are set explicitly everywhere below:
/// texture properties default to `.clamp` wrapping (so every tiled surface
/// smears its last texel across the wall), and to no mip filter (so anything at
/// distance aliases into shimmering noise).
final class MaterialLibrary {
    static let shared = MaterialLibrary()
    private var cache: [String: SCNMaterial] = [:]
    private let lock = NSLock()

    /// Bumped on quality change so cached materials get rebuilt at the new settings.
    private var generation = 0
    private var textureSize = 384

    func configure(quality: GraphicsSettings) {
        lock.lock(); defer { lock.unlock() }
        let size: Int
        switch quality.preset {
        case .low: size = 128
        case .medium: size = 256
        case .high: size = 384
        case .ultra: size = 512
        }
        if size != textureSize {
            textureSize = size
            cache.removeAll()
            TextureFactory.clearCache()
            generation += 1
        }
    }

    func clear() {
        lock.lock(); cache.removeAll(); lock.unlock()
        TextureFactory.clearCache()
    }

    // MARK: PBR surfaces

    /// - Parameter tiling: repeats per metre. `MeshBuilder` already emits UVs in
    ///   metres, so 0.5 means one texture tile every two metres.
    func pbr(_ kind: TextureKind, tiling: Float = 0.5, seed: UInt64 = 1,
             metalness: Float = 0, roughnessScale: Float = 1, tint: NSColor? = nil) -> SCNMaterial {
        let key = "pbr-\(kind)-\(tiling)-\(seed)-\(metalness)-\(roughnessScale)-\(tint?.description ?? "")-\(generation)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let tex = TextureFactory.surface(kind, size: textureSize, seed: seed)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = tex.diffuse
        if let n = tex.normal { m.normal.contents = n; m.normal.intensity = 1.0 }
        if let r = tex.roughness {
            m.roughness.contents = r
            m.roughness.intensity = CGFloat(roughnessScale)
        } else {
            m.roughness.contents = 0.85
        }
        m.metalness.contents = metalness
        if let tint { m.multiply.contents = tint }
        if let e = tex.emission {
            m.emission.contents = e
            m.emission.intensity = 0.6
        }
        let t = SCNMatrix4MakeScale(CGFloat(tiling), CGFloat(tiling), 1)
        for prop in [m.diffuse, m.normal, m.roughness, m.emission] {
            prop.wrapS = .repeat
            prop.wrapT = .repeat
            prop.mipFilter = .linear
            prop.magnificationFilter = .linear
            prop.minificationFilter = .linear
            prop.contentsTransform = t
        }
        m.isDoubleSided = false

        lock.lock(); cache[key] = m; lock.unlock()
        return m
    }

    /// Flat coloured PBR, for painted metal, plastics and simple props.
    func solid(_ color: NSColor, roughness: Float = 0.7, metalness: Float = 0,
               emission: NSColor? = nil, emissionIntensity: Float = 1) -> SCNMaterial {
        let key = "solid-\(color)-\(roughness)-\(metalness)-\(emission?.description ?? "")-\(emissionIntensity)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        if let emission {
            m.emission.contents = emission
            m.emission.intensity = CGFloat(emissionIntensity)
        }
        lock.lock(); cache[key] = m; lock.unlock()
        return m
    }

    /// Unlit emissive — light bulbs, embers, screens, muzzle flash cards.
    /// `.constant` skips shading entirely so these stay bright in pitch darkness.
    func glow(_ color: NSColor, intensity: Float = 1) -> SCNMaterial {
        let key = "glow-\(color)-\(intensity)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.emission.intensity = CGFloat(intensity)
        m.writesToDepthBuffer = true
        lock.lock(); cache[key] = m; lock.unlock()
        return m
    }

    /// Additive card for flashes and glows. Does not write depth, so overlapping
    /// cards accumulate instead of z-fighting.
    func additive(_ color: NSColor, image: CGImage? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image ?? color
        m.emission.contents = image ?? color
        m.multiply.contents = color
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        m.isDoubleSided = true
        return m
    }

    /// Glass: dark, reflective, and see-through enough to read silhouettes behind.
    func glass(tint: NSColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1),
               opacity: Float = 0.35) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = tint
        m.roughness.contents = 0.08
        m.metalness.contents = 0.0
        m.transparency = CGFloat(opacity)
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    /// Blood decal. The generated splat stores its coverage mask in the roughness
    /// channel, which is reused here as the transparency mask.
    func bloodDecal(seed: UInt64) -> SCNMaterial {
        let key = "decal-blood-\(seed)-\(generation)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let tex = TextureFactory.surface(.bloodSplat, size: 128, seed: seed)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = tex.diffuse
        m.transparent.contents = tex.roughness
        m.transparencyMode = .rgbZero      // white in the mask = opaque
        m.roughness.contents = 0.25
        m.metalness.contents = 0
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        m.isDoubleSided = true
        for prop in [m.diffuse, m.transparent] {
            prop.wrapS = .clamp; prop.wrapT = .clamp; prop.mipFilter = .linear
        }
        lock.lock(); cache[key] = m; lock.unlock()
        return m
    }

    // MARK: Sprite images used by effects

    /// Soft radial falloff, the basis of every flash/smoke/spark particle.
    static let softDot: CGImage = {
        let n = 64
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let dx = Float(x) / Float(n - 1) * 2 - 1
                let dy = Float(y) / Float(n - 1) * 2 - 1
                let d = sqrt(dx * dx + dy * dy)
                let a = clamp01(1 - d)
                let v = a * a
                let i = (y * n + x) * 4
                bytes[i + 0] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255
                bytes[i + 3] = UInt8(v * 255)
            }
        }
        return makeRGBA(bytes, n: n)
    }()

    /// Ragged star used for muzzle flash — a plain dot reads as a bubble.
    static let flashStar: CGImage = {
        let n = 128
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var rng = Rand(seed: 4242)
        // Random per-angle spike lengths, sampled with wrap so the star closes.
        var spikes = [Float](repeating: 0, count: 64)
        for i in 0..<64 { spikes[i] = rng.float(0.35, 1.0) }
        for y in 0..<n {
            for x in 0..<n {
                let dx = Float(x) / Float(n - 1) * 2 - 1
                let dy = Float(y) / Float(n - 1) * 2 - 1
                let d = sqrt(dx * dx + dy * dy)
                var ang = atan2(dy, dx) / (2 * .pi)
                if ang < 0 { ang += 1 }
                let fi = ang * 64
                let i0 = Int(fi) % 64, i1 = (i0 + 1) % 64
                let reach = lerp(spikes[i0], spikes[i1], fi - floor(fi))
                let core = clamp01(1 - d / 0.32)
                let star = clamp01(1 - d / max(reach, 0.05))
                let a = clamp01(core * core + star * star * star * 0.85)
                let i = (y * n + x) * 4
                bytes[i + 0] = 255
                bytes[i + 1] = UInt8(clamp01(0.72 + core * 0.28) * 255)
                bytes[i + 2] = UInt8(clamp01(0.30 + core * 0.60) * 255)
                bytes[i + 3] = UInt8(a * 255)
            }
        }
        return makeRGBA(bytes, n: n)
    }()

    /// Small irregular blob for blood droplets and gib chunks.
    static let gooDot: CGImage = {
        let n = 48
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let dx = Float(x) / Float(n - 1) * 2 - 1
                let dy = Float(y) / Float(n - 1) * 2 - 1
                let wob = Noise.fbm(dx * 2 + 5, dy * 2 + 5, octaves: 2, period: 4, seed: 7) * 0.32
                let d = sqrt(dx * dx + dy * dy) + wob - 0.16
                let a = smoothstep(1.0, 0.55, d)
                let i = (y * n + x) * 4
                bytes[i + 0] = 255; bytes[i + 1] = 40; bytes[i + 2] = 32
                bytes[i + 3] = UInt8(a * 255)
            }
        }
        return makeRGBA(bytes, n: n)
    }()

    private static func makeRGBA(_ bytes: [UInt8], n: Int) -> CGImage {
        var data = bytes
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

// MARK: - Colour helpers

extension NSColor {
    convenience init(rgb r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.init(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    /// The game's palette, kept in one place so the five levels stay coherent.
    enum Pal {
        static let blood = NSColor(rgb: 0.55, 0.05, 0.05)
        static let bloodBright = NSColor(rgb: 0.80, 0.09, 0.07)
        static let moonlight = NSColor(rgb: 0.55, 0.68, 0.95)
        static let candle = NSColor(rgb: 1.00, 0.62, 0.26)
        static let fire = NSColor(rgb: 1.00, 0.45, 0.12)
        static let sodium = NSColor(rgb: 1.00, 0.72, 0.36)
        static let fluorescent = NSColor(rgb: 0.78, 0.92, 0.95)
        static let hazard = NSColor(rgb: 0.95, 0.75, 0.10)
        static let toxic = NSColor(rgb: 0.55, 0.95, 0.35)
        static let ui = NSColor(rgb: 0.92, 0.88, 0.83)
        static let uiDim = NSColor(rgb: 0.55, 0.52, 0.50)
        static let uiAccent = NSColor(rgb: 0.85, 0.16, 0.12)
    }
}
