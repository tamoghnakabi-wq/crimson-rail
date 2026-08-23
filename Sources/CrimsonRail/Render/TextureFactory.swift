import Foundation
import CoreGraphics
import AppKit
import simd

// MARK: - Noise toolkit
//
// All lattice noise here is *periodic*: the hash wraps at `period`, so every
// texture tiles seamlessly. Non-tiling noise on a repeated wall shows a hard
// seam every few metres and is the fastest way to make a level look cheap.
enum Noise {
    @inline(__always)
    static func hash2(_ x: Int, _ y: Int, _ seed: UInt64) -> Float {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393)) &+ UInt64(bitPattern: Int64(y &* 668_265_263)) &+ seed
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h = h ^ (h >> 16)
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    @inline(__always)
    static func fade(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// Tileable value noise. `period` is in lattice cells.
    static func value(_ x: Float, _ y: Float, period: Int, seed: UInt64) -> Float {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let xf = x - Float(xi), yf = y - Float(yi)
        func wrap(_ v: Int) -> Int { ((v % period) + period) % period }
        let x0 = wrap(xi), x1 = wrap(xi + 1), y0 = wrap(yi), y1 = wrap(yi + 1)
        let v00 = hash2(x0, y0, seed), v10 = hash2(x1, y0, seed)
        let v01 = hash2(x0, y1, seed), v11 = hash2(x1, y1, seed)
        let u = fade(xf), v = fade(yf)
        return lerp(lerp(v00, v10, u), lerp(v01, v11, u), v)
    }

    /// Fractal Brownian motion; returns roughly 0..1.
    static func fbm(_ x: Float, _ y: Float, octaves: Int = 5, period: Int = 8,
                    lacunarity: Float = 2, gain: Float = 0.5, seed: UInt64) -> Float {
        var amp: Float = 1, freq: Float = 1, sum: Float = 0, norm: Float = 0
        var p = period
        for o in 0..<octaves {
            sum += amp * value(x * freq, y * freq, period: p, seed: seed &+ UInt64(o &* 7919))
            norm += amp
            amp *= gain
            freq *= lacunarity
            p = Int(Float(p) * lacunarity)
        }
        return norm > 0 ? sum / norm : 0
    }

    /// Ridged variant — veins, cracks, lightning, erosion channels.
    static func ridged(_ x: Float, _ y: Float, octaves: Int = 4, period: Int = 8, seed: UInt64) -> Float {
        var amp: Float = 1, freq: Float = 1, sum: Float = 0, norm: Float = 0
        var p = period
        for o in 0..<octaves {
            let n = value(x * freq, y * freq, period: p, seed: seed &+ UInt64(o &* 5443))
            sum += amp * (1 - abs(n * 2 - 1))
            norm += amp
            amp *= 0.5; freq *= 2; p *= 2
        }
        return norm > 0 ? sum / norm : 0
    }

    /// Tileable Worley/cellular. Returns (F1, cellHash) — F1 for stone joints and
    /// pores, cellHash for per-cell tinting (cobbles, tiles, scales).
    static func worley(_ x: Float, _ y: Float, period: Int, seed: UInt64) -> (f1: Float, cell: Float) {
        let xi = Int(floor(x)), yi = Int(floor(y))
        var best: Float = 8, bestCell: Float = 0
        for dy in -1...1 {
            for dx in -1...1 {
                let cx = xi + dx, cy = yi + dy
                func wrap(_ v: Int) -> Int { ((v % period) + period) % period }
                let wx = wrap(cx), wy = wrap(cy)
                let px = Float(cx) + hash2(wx, wy, seed)
                let py = Float(cy) + hash2(wx, wy, seed &+ 99_991)
                let d = (px - x) * (px - x) + (py - y) * (py - y)
                if d < best { best = d; bestCell = hash2(wx, wy, seed &+ 31_337) }
            }
        }
        return (sqrt(best), bestCell)
    }
}

// MARK: - Texture output

struct SurfaceTexture {
    var diffuse: CGImage
    var normal: CGImage?
    var roughness: CGImage?
    /// Emission mask, for things that glow (screens, embers, stained glass).
    var emission: CGImage?
}

enum TextureKind: Hashable {
    case concrete, crackedPlaster, brick, cobblestone, asphalt
    case woodPlank, rottenWood, bark
    case rustedMetal, metalPanel, labTile, grate
    case dirt, deadGrass, gravel, mud
    case graniteStone, marble, mossStone
    case rags(hue: Int)
    case rottenFlesh(hue: Int)
    case bloodSplat
    case stainedGlass
    case wallpaper
    case shingle
}

enum TextureFactory {
    private static var cache: [String: SurfaceTexture] = [:]
    private static let lock = NSLock()

    static func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    static func surface(_ kind: TextureKind, size: Int = 384, seed: UInt64 = 1) -> SurfaceTexture {
        let key = "\(kind)-\(size)-\(seed)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let made = build(kind, size: size, seed: seed)
        lock.lock(); cache[key] = made; lock.unlock()
        return made
    }

    // MARK: Buffers

    /// Per-pixel fields shared by every generator: albedo, height (for normals)
    /// and roughness. Writing all three in one pass keeps generation cheap.
    private struct Fields {
        var albedo: [SIMD3<Float>]
        var height: [Float]
        var rough: [Float]
        var emit: [Float]
        var hasEmit = false
        let n: Int
        init(_ n: Int) {
            self.n = n
            albedo = Array(repeating: .zero, count: n * n)
            height = Array(repeating: 0, count: n * n)
            rough = Array(repeating: 0.8, count: n * n)
            emit = Array(repeating: 0, count: n * n)
        }
    }

    private static func build(_ kind: TextureKind, size n: Int, seed: UInt64) -> SurfaceTexture {
        var f = Fields(n)
        let inv = 1.0 / Float(n)

        // Fill the fields. Each generator writes albedo/height/rough for one pixel.
        // Split across cores: texture generation is the bulk of level load time.
        let rowChunk = max(1, n / 8)
        let chunks = (n + rowChunk - 1) / rowChunk
        f.albedo.withUnsafeMutableBufferPointer { albedo in
            f.height.withUnsafeMutableBufferPointer { height in
                f.rough.withUnsafeMutableBufferPointer { rough in
                    f.emit.withUnsafeMutableBufferPointer { emit in
                        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                            let y0 = chunk * rowChunk
                            let y1 = min(y0 + rowChunk, n)
                            guard y0 < y1 else { return }
                            for py in y0..<y1 {
                                for px in 0..<n {
                                    let u = Float(px) * inv, v = Float(py) * inv
                                    let s = shade(kind, u: u, v: v, seed: seed)
                                    let i = py * n + px
                                    albedo[i] = s.albedo
                                    height[i] = s.height
                                    rough[i] = s.rough
                                    emit[i] = s.emit
                                }
                            }
                        }
                    }
                }
            }
        }
        f.hasEmit = f.emit.contains { $0 > 0.001 }

        let diffuse = imageRGB(f.albedo, n: n)
        let normal = normalMap(f.height, n: n, strength: normalStrength(kind))
        let roughImg = imageGray(f.rough, n: n)
        let emitImg = f.hasEmit ? imageGray(f.emit, n: n) : nil
        return SurfaceTexture(diffuse: diffuse, normal: normal, roughness: roughImg, emission: emitImg)
    }

    private static func normalStrength(_ kind: TextureKind) -> Float {
        switch kind {
        case .brick, .cobblestone, .grate, .labTile, .shingle: return 3.2
        case .woodPlank, .rottenWood, .metalPanel: return 2.0
        case .graniteStone, .mossStone, .bark: return 2.6
        // Ground surfaces are viewed at grazing angles across a wide area; wall
        // strength here reads as crawling speckle rather than texture.
        case .deadGrass, .dirt, .gravel, .mud, .asphalt: return 0.9
        case .rags, .rottenFlesh: return 1.4
        case .bloodSplat, .stainedGlass: return 0.4
        default: return 1.8
        }
    }

    // MARK: The generators

    private struct Sample {
        var albedo: SIMD3<Float>
        var height: Float
        var rough: Float
        var emit: Float = 0
    }

    private static func shade(_ kind: TextureKind, u: Float, v: Float, seed: UInt64) -> Sample {
        switch kind {

        case .concrete:
            let grain = Noise.fbm(u * 14, v * 14, octaves: 5, period: 14, seed: seed)
            let blotch = Noise.fbm(u * 3.5, v * 3.5, octaves: 3, period: 4, seed: seed &+ 12)
            let crack = smoothstep(0.72, 0.79, Noise.ridged(u * 6, v * 6, octaves: 4, period: 6, seed: seed &+ 5))
            var tone = 0.34 + grain * 0.11 + blotch * 0.11
            tone -= crack * 0.16
            let c = SIMD3<Float>(tone * 1.0, tone * 0.99, tone * 0.95)
            return Sample(albedo: c, height: grain * 0.5 - crack * 0.9, rough: 0.85 - blotch * 0.1)

        case .crackedPlaster:
            let base = Noise.fbm(u * 8, v * 8, octaves: 4, period: 8, seed: seed)
            let crack = smoothstep(0.62, 0.70, Noise.ridged(u * 4.5, v * 4.5, octaves: 5, period: 5, seed: seed &+ 71))
            // Patches where plaster has fallen away, showing brick beneath.
            let fallOff = smoothstep(0.55, 0.68, Noise.fbm(u * 2.2, v * 2.2, octaves: 3, period: 3, seed: seed &+ 3))
            let brickTone = brickPattern(u: u, v: v, seed: seed &+ 900)
            let plaster = SIMD3<Float>(0.52, 0.48, 0.43) * (0.72 + base * 0.4)
            let stain = smoothstep(0.4, 0.85, Noise.fbm(u * 3, v * 6, octaves: 4, period: 4, seed: seed &+ 41))
            var c = simd_mix(plaster, brickTone.color * 0.8, SIMD3(repeating: fallOff))
            c *= (1 - stain * 0.35)
            c *= (1 - crack * 0.5)
            return Sample(albedo: c, height: -crack * 1.2 - fallOff * 0.7 + base * 0.2, rough: 0.9)

        case .brick:
            let b = brickPattern(u: u, v: v, seed: seed)
            let grime = Noise.fbm(u * 4, v * 8, octaves: 4, period: 4, seed: seed &+ 17)
            let c = b.color * (0.75 + grime * 0.4)
            return Sample(albedo: c, height: b.height, rough: 0.88 - b.mortar * 0.1)

        case .cobblestone:
            let (f1, cell) = Noise.worley(u * 9, v * 9, period: 9, seed: seed)
            let joint = smoothstep(0.0, 0.22, f1)
            let grain = Noise.fbm(u * 26, v * 26, octaves: 3, period: 26, seed: seed &+ 8)
            var tone = 0.16 + cell * 0.16 + grain * 0.07
            tone *= (0.45 + joint * 0.55)
            let wet = Noise.fbm(u * 2, v * 2, octaves: 3, period: 2, seed: seed &+ 55)
            let c = SIMD3<Float>(tone * 1.0, tone * 1.02, tone * 1.06)
            return Sample(albedo: c, height: joint * 1.2 + grain * 0.2, rough: 0.55 + wet * 0.3)

        case .asphalt:
            let grain = Noise.fbm(u * 40, v * 40, octaves: 4, period: 40, seed: seed)
            let patch = Noise.fbm(u * 3, v * 3, octaves: 3, period: 3, seed: seed &+ 21)
            let crack = smoothstep(0.74, 0.80, Noise.ridged(u * 5, v * 5, octaves: 4, period: 5, seed: seed &+ 6))
            let tone = 0.075 + grain * 0.055 + patch * 0.045 - crack * 0.05
            return Sample(albedo: SIMD3(tone, tone * 1.01, tone * 1.05),
                          height: grain * 0.6 - crack * 1.0, rough: 0.78 + grain * 0.15)

        case .woodPlank, .rottenWood:
            let rotten = (kind == .rottenWood)
            let plankH: Float = 0.125
            let row = floor(v / plankH)
            let offset = Noise.hash2(Int(row), 0, seed) * 0.5
            let along = u + offset
            let inRow = (v / plankH) - row
            let seam = smoothstep(0.0, 0.05, inRow) * smoothstep(1.0, 0.95, inRow)
            let boardSeam = smoothstep(0.0, 0.02, fract(along * 3)) * smoothstep(1.0, 0.98, fract(along * 3))
            // Grain: stretched noise along the plank plus ring-like ridges.
            let grain = Noise.fbm(along * 30, v * 90, octaves: 4, period: 30, seed: seed &+ Int(row).magnitudeUInt)
            let rings = Noise.ridged(along * 7, v * 60, octaves: 3, period: 7, seed: seed &+ 3)
            let shade = 0.55 + grain * 0.3 + rings * 0.2
            var base = rotten ? SIMD3<Float>(0.17, 0.14, 0.11) : SIMD3<Float>(0.31, 0.21, 0.13)
            base *= shade
            if rotten {
                let rot = smoothstep(0.45, 0.8, Noise.fbm(u * 5, v * 5, octaves: 4, period: 5, seed: seed &+ 77))
                base = simd_mix(base, SIMD3(0.09, 0.10, 0.07), SIMD3(repeating: rot * 0.7))
            }
            let h = grain * 0.5 + rings * 0.3 - (1 - seam) * 1.0 - (1 - boardSeam) * 0.6
            return Sample(albedo: base, height: h, rough: rotten ? 0.95 : 0.78)

        case .bark:
            let vert = Noise.ridged(u * 8, v * 2.2, octaves: 5, period: 8, seed: seed)
            let grain = Noise.fbm(u * 30, v * 12, octaves: 3, period: 30, seed: seed &+ 4)
            let tone = 0.10 + vert * 0.12 + grain * 0.05
            return Sample(albedo: SIMD3(tone * 1.1, tone, tone * 0.85),
                          height: vert * 1.6 + grain * 0.3, rough: 0.94)

        case .rustedMetal:
            let rust = Noise.fbm(u * 6, v * 6, octaves: 5, period: 6, seed: seed)
            let patch = smoothstep(0.42, 0.72, Noise.fbm(u * 2.5, v * 2.5, octaves: 4, period: 3, seed: seed &+ 9))
            let pits = smoothstep(0.55, 0.9, Noise.fbm(u * 40, v * 40, octaves: 3, period: 40, seed: seed &+ 13))
            let steel = SIMD3<Float>(0.20, 0.21, 0.23) * (0.7 + rust * 0.5)
            let rustCol = SIMD3<Float>(0.34, 0.15, 0.06) * (0.6 + rust * 0.8)
            let c = simd_mix(steel, rustCol, SIMD3(repeating: patch))
            return Sample(albedo: c, height: pits * 0.8 + rust * 0.4 - patch * 0.3,
                          rough: 0.34 + patch * 0.55)

        case .metalPanel:
            let panelU = fract(u * 4), panelV = fract(v * 2)
            let seam = min(smoothstep(0.0, 0.025, panelU) * smoothstep(1.0, 0.975, panelU),
                           smoothstep(0.0, 0.05, panelV) * smoothstep(1.0, 0.95, panelV))
            let brushed = Noise.fbm(u * 200, v * 4, octaves: 2, period: 200, seed: seed)
            let grime = Noise.fbm(u * 3, v * 3, octaves: 4, period: 3, seed: seed &+ 2)
            let tone = (0.135 + brushed * 0.045) * (0.72 + grime * 0.4)
            // Rivets on the panel borders.
            let rivet = ringMask(fract(u * 4), fract(v * 2), seed: seed)
            return Sample(albedo: SIMD3(tone, tone * 1.02, tone * 1.08) * (1 - (1 - seam) * 0.4),
                          height: -(1 - seam) * 1.2 + rivet * 1.4 + brushed * 0.1,
                          rough: 0.42 + grime * 0.3)

        case .labTile:
            let tu = fract(u * 6), tv = fract(v * 6)
            let joint = min(smoothstep(0.0, 0.035, tu) * smoothstep(1.0, 0.965, tu),
                            smoothstep(0.0, 0.035, tv) * smoothstep(1.0, 0.965, tv))
            let cellVar = Noise.hash2(Int(u * 6), Int(v * 6), seed)
            let grime = Noise.fbm(u * 5, v * 5, octaves: 4, period: 5, seed: seed &+ 31)
            let stain = smoothstep(0.5, 0.9, Noise.fbm(u * 2.5, v * 2.5, octaves: 4, period: 3, seed: seed &+ 61))
            var tone = 0.235 + cellVar * 0.045 - grime * 0.11
            tone *= (0.55 + joint * 0.45)
            var c = SIMD3<Float>(tone * 0.98, tone, tone * 0.94)
            c = simd_mix(c, SIMD3(0.13, 0.11, 0.09), SIMD3(repeating: stain * 0.75))
            return Sample(albedo: c, height: joint * 1.0, rough: 0.28 + grime * 0.4 + stain * 0.3)

        case .grate:
            let gu = fract(u * 16), gv = fract(v * 16)
            let bar = max(smoothstep(0.42, 0.5, abs(gu - 0.5) * -1 + 0.5),
                          smoothstep(0.42, 0.5, abs(gv - 0.5) * -1 + 0.5))
            let solid = 1 - bar
            let rust = Noise.fbm(u * 8, v * 8, octaves: 4, period: 8, seed: seed)
            let tone = (0.10 + rust * 0.14) * (0.25 + solid * 0.75)
            return Sample(albedo: SIMD3(tone * 1.2, tone, tone * 0.9),
                          height: solid * 1.5, rough: 0.6 + rust * 0.3)

        case .dirt:
            let coarse = Noise.fbm(u * 8, v * 8, octaves: 5, period: 8, seed: seed)
            let fine = Noise.fbm(u * 45, v * 45, octaves: 3, period: 45, seed: seed &+ 11)
            let (peb, pcell) = Noise.worley(u * 22, v * 22, period: 22, seed: seed &+ 3)
            let pebble = smoothstep(0.24, 0.1, peb)
            var c = SIMD3<Float>(0.160, 0.130, 0.098) * (0.6 + coarse * 0.7 + fine * 0.25)
            c = simd_mix(c, SIMD3(0.16, 0.15, 0.14) * (0.5 + pcell), SIMD3(repeating: pebble * 0.8))
            return Sample(albedo: c, height: coarse * 0.5 + fine * 0.3 + pebble * 0.7, rough: 0.95)

        case .mud:
            let coarse = Noise.fbm(u * 6, v * 6, octaves: 5, period: 6, seed: seed)
            let puddle = smoothstep(0.52, 0.68, Noise.fbm(u * 3, v * 3, octaves: 4, period: 3, seed: seed &+ 19))
            let c = SIMD3<Float>(0.085, 0.070, 0.055) * (0.65 + coarse * 0.6)
            return Sample(albedo: simd_mix(c, c * 0.55, SIMD3(repeating: puddle)),
                          height: coarse * 0.6 - puddle * 0.5,
                          rough: 0.92 - puddle * 0.75)

        case .deadGrass:
            let clump = Noise.fbm(u * 12, v * 12, octaves: 5, period: 12, seed: seed)
            let blades = Noise.ridged(u * 70, v * 24, octaves: 3, period: 70, seed: seed &+ 27)
            let bare = smoothstep(0.55, 0.75, Noise.fbm(u * 4, v * 4, octaves: 3, period: 4, seed: seed &+ 33))
            let grass = SIMD3<Float>(0.165, 0.170, 0.092) * (0.55 + clump * 0.7 + blades * 0.3)
            let soil = SIMD3<Float>(0.145, 0.118, 0.086)
            return Sample(albedo: simd_mix(grass, soil, SIMD3(repeating: bare)),
                          height: blades * 0.6 + clump * 0.4, rough: 0.96)

        case .gravel:
            let (f1, cell) = Noise.worley(u * 26, v * 26, period: 26, seed: seed)
            let stone = smoothstep(0.34, 0.06, f1)
            let grain = Noise.fbm(u * 60, v * 60, octaves: 3, period: 60, seed: seed &+ 7)
            let tone = (0.145 + cell * 0.155 + grain * 0.06) * (0.45 + stone * 0.7)
            return Sample(albedo: SIMD3(tone, tone * 0.98, tone * 0.95),
                          height: stone * 1.3 + grain * 0.2, rough: 0.93)

        case .graniteStone:
            let (f1, cell) = Noise.worley(u * 5, v * 5, period: 5, seed: seed)
            let joint = smoothstep(0.0, 0.05, f1)
            let speck = Noise.fbm(u * 90, v * 90, octaves: 2, period: 90, seed: seed &+ 15)
            let weather = Noise.fbm(u * 4, v * 8, octaves: 4, period: 4, seed: seed &+ 23)
            var tone = 0.215 + cell * 0.055 + speck * 0.10
            tone *= (0.72 + joint * 0.28) * (0.72 + weather * 0.45)
            return Sample(albedo: SIMD3(tone * 1.02, tone, tone * 0.97),
                          height: joint * 1.4 + speck * 0.25, rough: 0.88)

        case .mossStone:
            let (f1, cell) = Noise.worley(u * 5, v * 5, period: 5, seed: seed)
            let joint = smoothstep(0.0, 0.06, f1)
            let speck = Noise.fbm(u * 80, v * 80, octaves: 2, period: 80, seed: seed &+ 15)
            let moss = smoothstep(0.42, 0.70, Noise.fbm(u * 6, v * 6, octaves: 5, period: 6, seed: seed &+ 88))
            var tone = 0.185 + cell * 0.06 + speck * 0.085
            tone *= (0.70 + joint * 0.30)
            let stoneCol = SIMD3<Float>(tone * 1.02, tone, tone * 0.96)
            let mossCol = SIMD3<Float>(0.055, 0.085, 0.035) * (0.7 + speck * 0.9)
            return Sample(albedo: simd_mix(stoneCol, mossCol, SIMD3(repeating: moss)),
                          height: joint * 1.4 + moss * 0.3, rough: 0.9)

        case .marble:
            let veinField = Noise.fbm(u * 3, v * 3, octaves: 4, period: 3, seed: seed)
            let vein = Noise.ridged(u * 2 + veinField * 1.5, v * 2, octaves: 4, period: 2, seed: seed &+ 45)
            let dirt = Noise.fbm(u * 5, v * 5, octaves: 4, period: 5, seed: seed &+ 12)
            let base: Float = 0.170 + veinField * 0.045 - dirt * 0.09
            let veinDark = smoothstep(0.6, 0.9, vein) * 0.22
            let tone = base - veinDark
            return Sample(albedo: SIMD3(tone * 1.0, tone * 0.985, tone * 0.95),
                          height: -veinDark * 0.4, rough: 0.30 + dirt * 0.4)

        case .wallpaper:
            // Damask-ish repeating motif, heavily water-stained and peeling.
            let su = fract(u * 4), sv = fract(v * 4)
            let motif = ringMask(su, sv, seed: seed &+ 1) * 0.6
                      + smoothstep(0.42, 0.5, 1 - abs(su - 0.5) - abs(sv - 0.5)) * 0.4
            let stain = smoothstep(0.35, 0.85, Noise.fbm(u * 2.5, v * 4, octaves: 5, period: 3, seed: seed &+ 5))
            let peel = smoothstep(0.66, 0.78, Noise.fbm(u * 3, v * 3, octaves: 4, period: 3, seed: seed &+ 66))
            var c = SIMD3<Float>(0.26, 0.20, 0.13) * (0.8 + motif * 0.55)
            c = simd_mix(c, SIMD3(0.10, 0.075, 0.05), SIMD3(repeating: stain * 0.8))
            c = simd_mix(c, SIMD3(0.14, 0.12, 0.10), SIMD3(repeating: peel))
            return Sample(albedo: c, height: motif * 0.3 - peel * 1.0, rough: 0.9)

        case .shingle:
            let rowH: Float = 0.16
            let row = floor(v / rowH)
            let off = (Int(row) % 2 == 0) ? 0 : Float(0.5)
            let cu = fract(u * 6 + off)
            let inRow = (v / rowH) - row
            let edge = smoothstep(0.0, 0.06, inRow) * smoothstep(0.0, 0.03, cu) * smoothstep(1.0, 0.97, cu)
            let wear = Noise.fbm(u * 12, v * 12, octaves: 4, period: 12, seed: seed)
            let cell = Noise.hash2(Int(u * 6 + off), Int(row), seed)
            let tone = (0.085 + cell * 0.05 + wear * 0.05) * (0.5 + edge * 0.6)
            return Sample(albedo: SIMD3(tone, tone * 1.02, tone * 1.05),
                          height: edge * 1.2, rough: 0.9)

        case .rags(let hue):
            // Torn, filthy clothing. `hue` picks the original dye, mostly buried
            // under grime so the palette stays readable against dark levels.
            var rng = Rand(seed: UInt64(hue) &* 7717 &+ 5)
            // Clothing on a corpse: whatever the dye once was, it is now filthy.
            // Keep the hues barely distinguishable and the values low, or a crowd
            // reads as brightly dressed mannequins rather than as the dead.
            let base = rng.float(0.045, 0.085)
            let dye = SIMD3<Float>(base * rng.float(0.85, 1.35),
                                   base * rng.float(0.85, 1.25),
                                   base * rng.float(0.80, 1.20))
            let weave = Noise.fbm(u * 120, v * 120, octaves: 2, period: 120, seed: seed)
            let grime = Noise.fbm(u * 5, v * 5, octaves: 5, period: 5, seed: seed &+ 9)
            let tear = smoothstep(0.70, 0.82, Noise.fbm(u * 7, v * 7, octaves: 4, period: 7, seed: seed &+ 44))
            var c = dye * (0.70 + weave * 0.30 + grime * 0.75)
            c = simd_mix(c, SIMD3(0.022, 0.019, 0.016), SIMD3(repeating: tear * 0.85))
            // Old blood at the hems.
            let blood = smoothstep(0.66, 0.85, Noise.fbm(u * 4, v * 9, octaves: 4, period: 4, seed: seed &+ 200))
            c = simd_mix(c, SIMD3(0.075, 0.013, 0.010), SIMD3(repeating: blood * 0.75))
            return Sample(albedo: c, height: weave * 0.3 + tear * 0.5, rough: 0.95)

        case .rottenFlesh(let hue):
            var rng = Rand(seed: UInt64(hue) &* 3313 &+ 11)
            // Grey-green and grey-violet, and *dark*. Skin lit by a weapon light at
            // close range picks up plenty of value on its own; authoring it light
            // as well turns every enemy into a pale mannequin.
            // Grey-green with a little warmth left in it. Pure grey reads as
            // stone under a white weapon light; a hint of red keeps it as tissue.
            let base = SIMD3<Float>(rng.float(0.132, 0.176), rng.float(0.118, 0.152), rng.float(0.098, 0.126))
            let mottle = Noise.fbm(u * 9, v * 9, octaves: 5, period: 9, seed: seed)
            let pores = Noise.fbm(u * 55, v * 55, octaves: 3, period: 55, seed: seed &+ 4)
            let bruise = smoothstep(0.45, 0.82, Noise.fbm(u * 4, v * 4, octaves: 4, period: 4, seed: seed &+ 71))
            let wound = smoothstep(0.72, 0.87, Noise.fbm(u * 6, v * 6, octaves: 5, period: 6, seed: seed &+ 133))
            var c = base * (0.74 + mottle * 0.38 + pores * 0.14)
            // Bruising: deep and violet, in large soft patches.
            c = simd_mix(c, SIMD3(0.058, 0.042, 0.060), SIMD3(repeating: bruise * 0.55))
            // Open wounds: dark red, wet, with a paler rim of exposed tissue.
            let rim = smoothstep(0.66, 0.74, Noise.fbm(u * 6, v * 6, octaves: 5, period: 6, seed: seed &+ 133))
            c = simd_mix(c, SIMD3(0.190, 0.075, 0.052), SIMD3(repeating: clamp01(rim - wound) * 0.7))
            c = simd_mix(c, SIMD3(0.115, 0.016, 0.013), SIMD3(repeating: wound))
            // Dried blood streaks running downward.
            let streak = smoothstep(0.70, 0.90, Noise.fbm(u * 9, v * 2.2, octaves: 4, period: 9, seed: seed &+ 411))
            c = simd_mix(c, SIMD3(0.062, 0.013, 0.011), SIMD3(repeating: streak * 0.55))
            // Grime, heaviest low down.
            let grime = Noise.fbm(u * 4, v * 4, octaves: 4, period: 4, seed: seed &+ 77)
            c *= 0.80 + grime * 0.34
            return Sample(albedo: c,
                          height: mottle * 0.5 + pores * 0.35 - wound * 0.6,
                          rough: 0.62 - wound * 0.3)

        case .bloodSplat:
            let blob = Noise.fbm(u * 5, v * 5, octaves: 5, period: 5, seed: seed)
            let d = simd_length(SIMD2(u - 0.5, v - 0.5)) * 2
            let mask = smoothstep(1.0, 0.15, d + (blob - 0.5) * 1.15)
            let depth = Noise.fbm(u * 14, v * 14, octaves: 4, period: 14, seed: seed &+ 3)
            let tone = 0.055 + depth * 0.075
            // Alpha lives in the roughness slot; the decal material reads it as a mask.
            return Sample(albedo: SIMD3(tone * 2.4, tone * 0.30, tone * 0.24),
                          height: mask * 0.4, rough: mask)

        case .stainedGlass:
            let (f1, cell) = Noise.worley(u * 5, v * 7, period: 5, seed: seed)
            let lead = smoothstep(0.0, 0.05, f1)
            var rng = Rand(seed: UInt64(cell * 9999))
            let hue = rng.float(0, 1)
            // Deep saturated jewel tones; the emission map makes them glow.
            var c = SIMD3<Float>(
                0.35 + 0.5 * abs(sin(hue * 6.28)),
                0.10 + 0.35 * abs(sin(hue * 6.28 + 2.1)),
                0.20 + 0.5 * abs(sin(hue * 6.28 + 4.2)))
            c *= (0.3 + lead * 0.9)
            return Sample(albedo: c, height: lead * 0.8, rough: 0.2,
                          emit: lead * (0.35 + cell * 0.5))
        }
    }

    // MARK: Pattern helpers

    private static func fract(_ x: Float) -> Float { x - floor(x) }

    private struct BrickSample { var color: SIMD3<Float>; var height: Float; var mortar: Float }

    private static func brickPattern(u: Float, v: Float, seed: UInt64) -> BrickSample {
        let rowsPerTile: Float = 10, colsPerTile: Float = 4
        let row = floor(v * rowsPerTile)
        let stagger: Float = (Int(row) % 2 == 0) ? 0 : 0.5
        let cu = fract(u * colsPerTile + stagger)
        let cv = fract(v * rowsPerTile)
        let mortarW: Float = 0.045, mortarH: Float = 0.09
        let inBrick = smoothstep(0, mortarW, cu) * smoothstep(1, 1 - mortarW, cu)
                    * smoothstep(0, mortarH, cv) * smoothstep(1, 1 - mortarH, cv)
        let cell = Noise.hash2(Int(u * colsPerTile + stagger), Int(row), seed)
        let grain = Noise.fbm(u * 40, v * 40, octaves: 3, period: 40, seed: seed &+ 2)
        // Fired-clay reds pulled well down so brick reads dark under moonlight.
        let brick = SIMD3<Float>(0.205 + cell * 0.10, 0.088 + cell * 0.045, 0.065 + cell * 0.030)
                  * (0.75 + grain * 0.45)
        let mortarCol = SIMD3<Float>(0.20, 0.19, 0.175) * (0.7 + grain * 0.5)
        let c = simd_mix(mortarCol, brick, SIMD3(repeating: inBrick))
        return BrickSample(color: c, height: inBrick * 1.3 + grain * 0.15, mortar: 1 - inBrick)
    }

    /// Soft ring/dot used for rivets and wallpaper motifs.
    private static func ringMask(_ u: Float, _ v: Float, seed: UInt64) -> Float {
        let d = simd_length(SIMD2(u - 0.5, v - 0.5))
        return smoothstep(0.30, 0.24, d) * smoothstep(0.14, 0.20, d)
    }

    // MARK: Image assembly

    private static func imageRGB(_ px: [SIMD3<Float>], n: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            let c = px[i]
            // Textures feed a linear PBR pipeline but CGImage is sRGB-tagged, so
            // encode here; skipping this washes every surface out.
            bytes[i * 4 + 0] = encodeSRGB(c.x)
            bytes[i * 4 + 1] = encodeSRGB(c.y)
            bytes[i * 4 + 2] = encodeSRGB(c.z)
            bytes[i * 4 + 3] = 255
        }
        return makeImage(bytes, n: n)
    }

    private static func imageGray(_ px: [Float], n: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            let g = UInt8(clamp01(px[i]) * 255)
            bytes[i * 4 + 0] = g; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = g; bytes[i * 4 + 3] = 255
        }
        return makeImage(bytes, n: n)
    }

    /// Sobel over the height field. Tangent-space normal, +Y up, wrapped so the
    /// derivative is seamless at the tile border too.
    private static func normalMap(_ h: [Float], n: Int, strength: Float) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
            h[((y % n) + n) % n * n + ((x % n) + n) % n]
        }
        for y in 0..<n {
            for x in 0..<n {
                let dx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1))
                       - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))
                let dy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1))
                       - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1))
                let nrm = simd_normalize(SIMD3(-dx * strength, -dy * strength, 1))
                let i = y * n + x
                bytes[i * 4 + 0] = UInt8(clamp01(nrm.x * 0.5 + 0.5) * 255)
                bytes[i * 4 + 1] = UInt8(clamp01(nrm.y * 0.5 + 0.5) * 255)
                bytes[i * 4 + 2] = UInt8(clamp01(nrm.z * 0.5 + 0.5) * 255)
                bytes[i * 4 + 3] = 255
            }
        }
        // Normal maps are data, not colour — tag device RGB with no sRGB curve.
        return makeImage(bytes, n: n, linear: true)
    }

    @inline(__always)
    private static func encodeSRGB(_ linear: Float) -> UInt8 {
        let c = clamp01(linear)
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8(clamp01(s) * 255)
    }

    private static func makeImage(_ bytes: [UInt8], n: Int, linear: Bool = false) -> CGImage {
        var data = bytes
        let cs = linear ? CGColorSpaceCreateDeviceRGB() : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let ctx = CGContext(data: &data, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

private extension Int {
    /// Small convenience for folding a row index into a noise seed.
    var magnitudeUInt: UInt64 { UInt64(abs(self)) }
}
