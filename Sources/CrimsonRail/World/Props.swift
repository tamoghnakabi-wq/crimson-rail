import Foundation
import SceneKit
import AppKit
import simd

/// Procedural set dressing. Every prop is built from `MeshBuilder` primitives so
/// the game ships with no asset files, and every one takes a seed so a street of
/// twenty of the same prop still reads as twenty different objects.
enum Props {
    static var mats: MaterialLibrary { .shared }

    // MARK: - Ground

    /// Undulating ground plane. `heightScale` 0 gives a dead-flat floor (interiors).
    static func ground(size: Float, kind: TextureKind, tiling: Float = 0.35,
                       heightScale: Float = 0.25, divisions: Int = 40, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        m.addHeightGrid(origin: SIMD3(-size / 2, 0, -size / 2),
                        size: SIMD2(size, size),
                        divisions: SIMD2(divisions, divisions),
                        uvScale: 1) { x, z in
            guard heightScale > 0 else { return 0 }
            let n = Noise.fbm(x * 0.045, z * 0.045, octaves: 4, period: 16, seed: seed)
            let fine = Noise.fbm(x * 0.22, z * 0.22, octaves: 3, period: 32, seed: seed &+ 7)
            return (n - 0.5) * heightScale * 2 + (fine - 0.5) * heightScale * 0.5
        }
        let node = m.node(material: mats.pbr(kind, tiling: tiling, seed: seed), name: "ground")
        node.castsShadow = false
        return node
    }

    // MARK: - Cemetery

    static func gravestone(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let style = rng.int(0, 3)
        let w = rng.float(0.5, 0.85), t = rng.float(0.11, 0.18)
        let h = rng.float(0.7, 1.5)

        switch style {
        case 0: // slab with a rounded top, approximated by a stepped cap
            m.addBox(center: SIMD3(0, h / 2, 0), size: SIMD3(w, h, t), uvScale: 1)
            m.addBox(center: SIMD3(0, h + 0.05, 0), size: SIMD3(w * 0.82, 0.10, t * 0.98))
            m.addBox(center: SIMD3(0, h + 0.13, 0), size: SIMD3(w * 0.55, 0.08, t * 0.96))
        case 1: // cross
            m.addBox(center: SIMD3(0, h / 2, 0), size: SIMD3(w * 0.28, h, t))
            m.addBox(center: SIMD3(0, h * 0.74, 0), size: SIMD3(w, w * 0.26, t * 0.98))
            m.addBox(center: SIMD3(0, 0.06, 0), size: SIMD3(w * 1.1, 0.12, t * 2.2))
        case 2: // obelisk
            let base = h * 1.4
            m.addBox(center: SIMD3(0, 0.09, 0), size: SIMD3(w * 1.3, 0.18, w * 1.3))
            m.addPrism(center: SIMD3(0, 0.18, 0), radii: Array(repeating: w * 0.42, count: 4),
                       height: base, topScale: 0.62, yaw: .pi / 4, uvScale: 1)
            m.addPrism(center: SIMD3(0, 0.18 + base, 0), radii: Array(repeating: w * 0.26, count: 4),
                       height: w * 0.55, topScale: 0.02, yaw: .pi / 4, uvScale: 1)
        default: // broken stump
            m.addBox(center: SIMD3(0, h * 0.28, 0), size: SIMD3(w, h * 0.56, t))
            m.addBox(center: SIMD3(rng.float(-0.1, 0.1), h * 0.6, 0),
                     size: SIMD3(w * 0.6, h * 0.18, t), yaw: rng.float(-0.3, 0.3))
        }
        m.jitter(0.012, seed: seed &+ 5)
        let node = m.node(material: mats.pbr(.mossStone, tiling: 1.6, seed: seed % 4), name: "prop")
        node.simdEulerAngles = SIMD3(rng.float(-0.06, 0.06), rng.float(0, 2 * .pi), rng.float(-0.09, 0.09))
        return node
    }

    static func mausoleum(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let w: Float = rng.float(3.0, 4.2), d: Float = rng.float(3.2, 4.4), h: Float = rng.float(2.6, 3.2)
        // Body with the entry face left open — the doorway is a separate dark recess.
        m.addBox(center: SIMD3(0, h / 2, 0), size: SIMD3(w, h, d), uvScale: 1, faces: [.back, .left, .right, .top])
        // Front wall split around a door hole.
        let doorW: Float = 1.05, doorH: Float = 2.0
        let side = (w - doorW) / 2
        m.addBox(center: SIMD3(-(doorW / 2 + side / 2), h / 2, d / 2), size: SIMD3(side, h, 0.25))
        m.addBox(center: SIMD3(doorW / 2 + side / 2, h / 2, d / 2), size: SIMD3(side, h, 0.25))
        m.addBox(center: SIMD3(0, doorH + (h - doorH) / 2, d / 2), size: SIMD3(doorW, h - doorH, 0.25))
        // Recessed interior so the doorway reads as depth, not a painted rectangle.
        m.addBox(center: SIMD3(0, doorH / 2, d / 2 - 0.7), size: SIMD3(doorW, doorH, 1.2), faces: [.back, .left, .right, .top])
        // Cornice and pediment.
        m.addBox(center: SIMD3(0, h + 0.12, 0), size: SIMD3(w + 0.35, 0.24, d + 0.35))
        m.addPrism(center: SIMD3(0, h + 0.24, 0), radii: [w * 0.62, w * 0.62, w * 0.62],
                   height: 0.75, topScale: 0.05, yaw: 0, uvScale: 1)
        // Columns either side of the door.
        for s in [-1, 1] as [Float] {
            m.addTube(base: SIMD3(s * (doorW / 2 + 0.22), 0, d / 2 + 0.14), height: h - 0.3,
                      bottomRadius: 0.16, topRadius: 0.14, segments: 8, uvScale: 1)
        }
        let node = m.node(material: mats.pbr(.graniteStone, tiling: 0.7, seed: seed), name: "prop")
        node.simdEulerAngles = SIMD3(0, rng.float(0, 2 * .pi), 0)
        return node
    }

    /// Wrought-iron railing run, `length` metres along +X.
    static func ironFence(length: Float, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        let spacing: Float = 0.22
        let count = max(Int(length / spacing), 1)
        let h: Float = 1.5
        for i in 0...count {
            let x = -length / 2 + Float(i) * spacing
            m.addBox(center: SIMD3(x, h / 2, 0), size: SIMD3(0.035, h, 0.035))
            // Spear tip
            m.addPrism(center: SIMD3(x, h, 0), radii: [0.035, 0.035, 0.035, 0.035],
                       height: 0.13, topScale: 0.05, yaw: .pi / 4)
        }
        for y in [h * 0.22, h * 0.86] {
            m.addBox(center: SIMD3(0, y, 0), size: SIMD3(length, 0.05, 0.05))
        }
        // Posts
        for s in [-1, 1] as [Float] {
            m.addBox(center: SIMD3(s * length / 2, h * 0.58, 0), size: SIMD3(0.11, h * 1.16, 0.11))
        }
        let node = m.node(material: mats.pbr(.rustedMetal, tiling: 3.0, seed: seed, metalness: 0.85), name: "prop")
        return node
    }

    /// Bare, clawed tree. Recursive branching kept shallow — these are silhouettes
    /// against the sky, not hero assets.
    static func deadTree(seed: UInt64, scale: Float = 1) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()

        func branch(from: SIMD3<Float>, dir: SIMD3<Float>, length: Float, radius: Float, depth: Int) {
            guard depth > 0, radius > 0.012 else { return }
            let segs = depth > 2 ? 3 : 2
            var p = from
            var d = dir
            var r = radius
            for s in 0..<segs {
                let segLen = length / Float(segs)
                let nd = simd_normalize(d + SIMD3(rng.gaussian(0, 0.22), rng.gaussian(0, 0.10), rng.gaussian(0, 0.22)))
                let next = p + nd * segLen
                let nr = r * 0.78
                // Oriented tube: build along +Y then rotate into place by
                // constructing the prism ring manually.
                addOrientedTube(&m, from: p, to: next, r0: r, r1: nr, segments: depth > 2 ? 8 : 5)
                p = next; d = nd; r = nr
                if s == segs - 1 { break }
            }
            let children = depth > 2 ? rng.int(2, 3) : rng.int(1, 2)
            for _ in 0..<children {
                let spread = rng.float(0.45, 1.05)
                let axis = simd_normalize(SIMD3(rng.gaussian(), rng.gaussian(0, 0.3), rng.gaussian()))
                let nd = simd_normalize(d + axis * spread)
                branch(from: p, dir: nd, length: length * rng.float(0.55, 0.75), radius: r * rng.float(0.7, 0.88), depth: depth - 1)
            }
        }

        let h = rng.float(3.4, 5.2) * scale
        branch(from: .zero, dir: SIMD3(rng.gaussian(0, 0.06), 1, rng.gaussian(0, 0.06)),
               length: h * 0.55, radius: 0.20 * scale, depth: 4)
        // Root flare
        m.addPrism(center: SIMD3(0, -0.1, 0), radii: (0..<7).map { _ in rng.float(0.28, 0.46) * scale },
                   height: 0.45 * scale, topScale: 0.5, uvScale: 1)

        let node = m.node(material: mats.pbr(.bark, tiling: 2.2, seed: seed % 3), name: "prop")
        node.simdEulerAngles = SIMD3(0, rng.float(0, 2 * .pi), 0)
        return node
    }

    /// Tube between two arbitrary points — branches, pipes, cables, hanging chains.
    static func addOrientedTube(_ m: inout MeshBuilder, from a: SIMD3<Float>, to b: SIMD3<Float>,
                                r0: Float, r1: Float, segments: Int = 8) {
        let axis = b - a
        let len = simd_length(axis)
        guard len > 1e-4 else { return }
        let f = axis / len
        // Any perpendicular pair works; pick the world axis least aligned with f.
        let ref: SIMD3<Float> = abs(f.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(ref, f))
        let v = simd_cross(f, u)
        var ring0: [SIMD3<Float>] = [], ring1: [SIMD3<Float>] = []
        for i in 0..<segments {
            let ang = Float(i) / Float(segments) * 2 * .pi
            let dir = u * cos(ang) + v * sin(ang)
            ring0.append(a + dir * r0)
            ring1.append(b + dir * r1)
        }
        for i in 0..<segments {
            let j = (i + 1) % segments
            m.addQuad(ring0[i], ring0[j], ring1[j], ring1[i], uvScale: 1)
        }
    }

    // MARK: - Architecture

    /// Straight wall run along +X, optionally punched with openings.
    /// `openings` are (centerX, width, sillHeight, openingHeight).
    static func wall(length: Float, height: Float, thickness: Float = 0.3,
                     kind: TextureKind, tiling: Float = 0.45, seed: UInt64,
                     openings: [(x: Float, w: Float, sill: Float, h: Float)] = []) -> SCNNode {
        var m = MeshBuilder()
        if openings.isEmpty {
            m.addBox(center: SIMD3(0, height / 2, 0), size: SIMD3(length, height, thickness), uvScale: 1)
        } else {
            // Split the run into solid spans between openings, then fill above and
            // below each hole. Simpler and more robust than CSG.
            let sorted = openings.sorted { $0.x < $1.x }
            var cursor = -length / 2
            for o in sorted {
                let left = o.x - o.w / 2
                if left > cursor {
                    let w = left - cursor
                    m.addBox(center: SIMD3(cursor + w / 2, height / 2, 0), size: SIMD3(w, height, thickness), uvScale: 1)
                }
                if o.sill > 0.01 {
                    m.addBox(center: SIMD3(o.x, o.sill / 2, 0), size: SIMD3(o.w, o.sill, thickness), uvScale: 1)
                }
                let top = o.sill + o.h
                if top < height {
                    m.addBox(center: SIMD3(o.x, top + (height - top) / 2, 0),
                             size: SIMD3(o.w, height - top, thickness), uvScale: 1)
                }
                cursor = max(cursor, o.x + o.w / 2)
            }
            if cursor < length / 2 {
                let w = length / 2 - cursor
                m.addBox(center: SIMD3(cursor + w / 2, height / 2, 0), size: SIMD3(w, height, thickness), uvScale: 1)
            }
        }
        return m.node(material: mats.pbr(kind, tiling: tiling, seed: seed), name: "wall")
    }

    static func floorSlab(width: Float, depth: Float, kind: TextureKind, tiling: Float = 0.4,
                          seed: UInt64, y: Float = 0) -> SCNNode {
        var m = MeshBuilder()
        m.addQuad(SIMD3(-width / 2, y, -depth / 2), SIMD3(width / 2, y, -depth / 2),
                  SIMD3(width / 2, y, depth / 2), SIMD3(-width / 2, y, depth / 2),
                  uvScale: 1, normal: SIMD3(0, 1, 0))
        let n = m.node(material: mats.pbr(kind, tiling: tiling, seed: seed), name: "floor")
        n.castsShadow = false
        return n
    }

    static func ceiling(width: Float, depth: Float, height: Float, kind: TextureKind,
                        tiling: Float = 0.4, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        // Wound so the visible face points down.
        m.addQuad(SIMD3(-width / 2, height, depth / 2), SIMD3(width / 2, height, depth / 2),
                  SIMD3(width / 2, height, -depth / 2), SIMD3(-width / 2, height, -depth / 2),
                  uvScale: 1, normal: SIMD3(0, -1, 0))
        return m.node(material: mats.pbr(kind, tiling: tiling, seed: seed), name: "ceiling")
    }

    static func stairs(steps: Int, width: Float, rise: Float, run: Float,
                       kind: TextureKind, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        for i in 0..<steps {
            let y = Float(i) * rise
            let z = Float(i) * run
            m.addBox(center: SIMD3(0, y + rise / 2, z + run / 2), size: SIMD3(width, rise, run), uvScale: 1)
        }
        return m.node(material: mats.pbr(kind, tiling: 0.8, seed: seed), name: "stairs")
    }

    static func column(height: Float, radius: Float, kind: TextureKind, seed: UInt64,
                       fluted: Bool = true) -> SCNNode {
        var m = MeshBuilder()
        let segs = fluted ? 16 : 10
        var radii = [Float](repeating: radius, count: segs)
        if fluted { for i in 0..<segs where i % 2 == 0 { radii[i] = radius * 0.9 } }
        m.addBox(center: SIMD3(0, 0.09, 0), size: SIMD3(radius * 2.6, 0.18, radius * 2.6))
        m.addPrism(center: SIMD3(0, 0.18, 0), radii: radii, height: height - 0.5, topScale: 0.88, uvScale: 1)
        m.addBox(center: SIMD3(0, height - 0.2, 0), size: SIMD3(radius * 2.5, 0.24, radius * 2.5))
        return m.node(material: mats.pbr(kind, tiling: 1.0, seed: seed), name: "prop")
    }

    /// Pointed gothic arch, used for spire windows and manor doorways.
    static func gothicArch(width: Float, height: Float, depth: Float,
                           kind: TextureKind, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        let segs = 10
        let springLine = height * 0.6
        for s in [-1, 1] as [Float] {
            m.addBox(center: SIMD3(s * width / 2, springLine / 2, 0), size: SIMD3(0.16, springLine, depth))
        }
        // Two circular arcs meeting at a point.
        for i in 0..<segs {
            let t0 = Float(i) / Float(segs), t1 = Float(i + 1) / Float(segs)
            for s in [-1, 1] as [Float] {
                func pt(_ t: Float) -> SIMD3<Float> {
                    let a = t * (.pi / 2) * 0.82
                    return SIMD3(s * (width / 2) * cos(a), springLine + (height - springLine) * sin(a), 0)
                }
                let p0 = pt(t0), p1 = pt(t1)
                addOrientedTube(&m, from: p0, to: p1, r0: 0.09, r1: 0.09, segments: 5)
                _ = depth
            }
        }
        return m.node(material: mats.pbr(kind, tiling: 1.2, seed: seed), name: "prop")
    }

    // MARK: - Furniture

    static func table(width: Float = 1.6, depth: Float = 0.9, height: Float = 0.78, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        m.addBox(center: SIMD3(0, height, 0), size: SIMD3(width, 0.07, depth), uvScale: 1)
        let inset: Float = 0.11
        for sx in [-1, 1] as [Float] {
            for sz in [-1, 1] as [Float] {
                m.addBox(center: SIMD3(sx * (width / 2 - inset), height / 2, sz * (depth / 2 - inset)),
                         size: SIMD3(0.09, height, 0.09))
            }
        }
        return m.node(material: mats.pbr(.woodPlank, tiling: 1.4, seed: seed), name: "prop")
    }

    static func chair(seed: UInt64, toppled: Bool = false) -> SCNNode {
        var m = MeshBuilder()
        let h: Float = 0.45
        m.addBox(center: SIMD3(0, h, 0), size: SIMD3(0.44, 0.06, 0.44), uvScale: 1)
        for sx in [-1, 1] as [Float] {
            for sz in [-1, 1] as [Float] {
                m.addBox(center: SIMD3(sx * 0.17, h / 2, sz * 0.17), size: SIMD3(0.05, h, 0.05))
            }
        }
        m.addBox(center: SIMD3(0, h + 0.34, -0.19), size: SIMD3(0.42, 0.62, 0.05))
        let node = m.node(material: mats.pbr(.woodPlank, tiling: 2.0, seed: seed), name: "prop")
        if toppled {
            var rng = Rand(seed: seed)
            node.simdEulerAngles = SIMD3(rng.float(1.2, 1.8) * rng.sign(), rng.float(0, 6.28), rng.float(-0.4, 0.4))
            node.simdPosition.y = 0.22
        }
        return node
    }

    static func bookshelf(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let w: Float = 1.1, h: Float = 2.1, d: Float = 0.32
        m.addBox(center: SIMD3(0, h / 2, -d / 2 + 0.02), size: SIMD3(w, h, 0.04))
        for s in [-1, 1] as [Float] {
            m.addBox(center: SIMD3(s * w / 2, h / 2, 0), size: SIMD3(0.05, h, d))
        }
        let shelves = 5
        for i in 0...shelves {
            let y = 0.06 + Float(i) * (h - 0.12) / Float(shelves)
            m.addBox(center: SIMD3(0, y, 0), size: SIMD3(w, 0.04, d))
        }
        let node = SCNNode()
        node.addChildNode(m.node(material: mats.pbr(.rottenWood, tiling: 1.6, seed: seed)))
        // Books as thin coloured slabs, gappy so the shelf looks ransacked.
        var bm = MeshBuilder()
        for i in 0..<shelves {
            let y = 0.10 + Float(i) * (h - 0.12) / Float(shelves)
            var x = -w / 2 + 0.08
            while x < w / 2 - 0.08 {
                if rng.chance(0.72) {
                    let bw = rng.float(0.025, 0.05), bh = rng.float(0.19, 0.27)
                    bm.addBox(center: SIMD3(x + bw / 2, y + bh / 2, 0.02),
                              size: SIMD3(bw, bh, d * 0.7), yaw: rng.float(-0.05, 0.05))
                    x += bw + 0.004
                } else {
                    x += rng.float(0.03, 0.12)
                }
            }
        }
        node.addChildNode(bm.node(material: mats.pbr(.rags(hue: Int(seed % 7)), tiling: 6, seed: seed &+ 3)))
        return node
    }

    static func portrait(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let w = rng.float(0.55, 0.95), h = w * rng.float(1.15, 1.5)
        m.addBox(center: .zero, size: SIMD3(w, h, 0.06), uvScale: 1)
        m.addBox(center: SIMD3(0, 0, 0.035), size: SIMD3(w - 0.10, h - 0.10, 0.02))
        let node = SCNNode()
        node.addChildNode(m.node(material: mats.pbr(.woodPlank, tiling: 3, seed: seed)))
        // Canvas: a dark smear that reads as a ruined old portrait.
        var cm = MeshBuilder()
        cm.addQuad(SIMD3(-(w - 0.12) / 2, -(h - 0.12) / 2, 0.05), SIMD3((w - 0.12) / 2, -(h - 0.12) / 2, 0.05),
                   SIMD3((w - 0.12) / 2, (h - 0.12) / 2, 0.05), SIMD3(-(w - 0.12) / 2, (h - 0.12) / 2, 0.05))
        node.addChildNode(cm.node(material: mats.pbr(.marble, tiling: 1.4, seed: seed &+ 21,
                                                     tint: NSColor(rgb: 0.30, 0.24, 0.18))))
        return node
    }

    static func chandelier(seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        let node = SCNNode()
        let arms = 6
        let r: Float = 0.55
        m.addTube(base: SIMD3(0, 0.0, 0), height: 0.7, bottomRadius: 0.02, topRadius: 0.02, segments: 5)
        for i in 0..<arms {
            let a = Float(i) / Float(arms) * 2 * .pi
            let p = SIMD3(cos(a) * r, -0.3, sin(a) * r)
            addOrientedTube(&m, from: SIMD3(0, 0, 0), to: p, r0: 0.02, r1: 0.02, segments: 5)
            m.addTube(base: p, height: 0.12, bottomRadius: 0.045, topRadius: 0.06, segments: 6)
        }
        node.addChildNode(m.node(material: mats.pbr(.rustedMetal, tiling: 5, seed: seed, metalness: 0.9)))
        // Candle flames
        for i in 0..<arms {
            let a = Float(i) / Float(arms) * 2 * .pi
            let flame = SCNNode(geometry: SCNSphere(radius: 0.035))
            flame.geometry?.materials = [mats.glow(NSColor.Pal.candle, intensity: 3.5)]
            flame.simdPosition = SIMD3(cos(a) * r, -0.15, sin(a) * r)
            flame.name = "flame"
            node.addChildNode(flame)
        }
        return node
    }

    // MARK: - Street

    static func wreckedCar(seed: UInt64, burnt: Bool = false) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let L: Float = rng.float(3.9, 4.5), W: Float = rng.float(1.65, 1.85)
        // Lower body
        m.addBox(center: SIMD3(0, 0.52, 0), size: SIMD3(W, 0.55, L), uvScale: 1)
        // Bonnet / boot
        m.addBox(center: SIMD3(0, 0.80, L * 0.30), size: SIMD3(W * 0.94, 0.16, L * 0.36))
        m.addBox(center: SIMD3(0, 0.80, -L * 0.34), size: SIMD3(W * 0.94, 0.16, L * 0.30))
        // Cabin, tapered and crumpled
        m.addPrism(center: SIMD3(0, 0.80, -L * 0.02),
                   radii: [W * 0.48, W * 0.52, W * 0.48, W * 0.52], height: 0.62,
                   topScale: 0.80, yaw: .pi / 4, topTilt: SIMD2(rng.float(-0.08, 0.08), 0), uvScale: 1)
        // Wheels
        for sx in [-1, 1] as [Float] {
            for sz in [-1, 1] as [Float] {
                let flat = rng.chance(0.35)
                m.addPrism(center: SIMD3(sx * (W / 2 - 0.05) - sx * 0.06, flat ? 0.10 : 0.14, sz * L * 0.32),
                           radii: (0..<10).map { i in (flat && i > 6) ? 0.20 : 0.31 },
                           height: 0.22, yaw: rng.float(0, 1), uvScale: 2, capTop: false)
            }
        }
        m.jitter(0.03, seed: seed &+ 11)

        let node = SCNNode()
        let bodyTint: NSColor = burnt
            ? NSColor(rgb: 0.10, 0.09, 0.09)
            : [NSColor(rgb: 0.30, 0.10, 0.10), NSColor(rgb: 0.14, 0.20, 0.28),
               NSColor(rgb: 0.22, 0.22, 0.24), NSColor(rgb: 0.20, 0.24, 0.16)][rng.int(0, 3)]
        node.addChildNode(m.node(material: mats.pbr(.rustedMetal, tiling: 1.1, seed: seed,
                                                    metalness: burnt ? 0.4 : 0.75, tint: bodyTint)))
        if !burnt {
            // Glass, mostly shattered out — only some cars keep a windscreen.
            if rng.chance(0.5) {
                var gm = MeshBuilder()
                gm.addBox(center: SIMD3(0, 0.95, L * 0.10), size: SIMD3(W * 0.80, 0.42, 0.03))
                node.addChildNode(gm.node(material: mats.glass()))
            }
        }
        node.simdEulerAngles = SIMD3(rng.float(-0.04, 0.04), rng.float(0, 2 * .pi), rng.float(-0.05, 0.05))
        return node
    }

    static func streetlight(seed: UInt64, working: Bool) -> SCNNode {
        var m = MeshBuilder()
        let h: Float = 5.4
        m.addPrism(center: SIMD3(0, 0, 0), radii: Array(repeating: 0.22, count: 8), height: 0.35, topScale: 0.7)
        m.addTube(base: SIMD3(0, 0.3, 0), height: h, bottomRadius: 0.10, topRadius: 0.075, segments: 8)
        // Curved arm approximated by three chords.
        var p = SIMD3<Float>(0, h + 0.3, 0)
        for i in 0..<3 {
            let t = Float(i + 1) / 3
            let next = SIMD3<Float>(0, h + 0.3 + sin(t * 1.1) * 0.55, t * 1.5)
            addOrientedTube(&m, from: p, to: next, r0: 0.075, r1: 0.065, segments: 6)
            p = next
        }
        m.addPrism(center: SIMD3(0, p.y - 0.22, p.z), radii: Array(repeating: 0.26, count: 8),
                   height: 0.20, topScale: 1.6, uvScale: 2)
        let node = SCNNode()
        node.addChildNode(m.node(material: mats.pbr(.rustedMetal, tiling: 2.0, seed: seed, metalness: 0.8)))
        let lamp = SCNNode(geometry: SCNSphere(radius: 0.19))
        lamp.simdPosition = SIMD3(0, p.y - 0.26, p.z)
        lamp.name = working ? "lamp" : "deadlamp"
        lamp.geometry?.materials = [working ? mats.glow(NSColor.Pal.sodium, intensity: 4.0)
                                            : mats.solid(NSColor(rgb: 0.10, 0.09, 0.08), roughness: 0.4)]
        node.addChildNode(lamp)
        return node
    }

    static func dumpster(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let w: Float = 1.9, h: Float = 1.25, d: Float = 1.1
        m.addBox(center: SIMD3(0, h / 2, 0), size: SIMD3(w, h, d), uvScale: 1, faces: [.front, .back, .left, .right])
        m.addBox(center: SIMD3(0, h * 0.08, 0), size: SIMD3(w - 0.06, 0.08, d - 0.06))
        // Lid, thrown open
        let open = rng.float(0.9, 2.1)
        m.addBox(center: SIMD3(0, h + sin(open) * 0.5, -d / 2 - cos(open) * 0.5),
                 size: SIMD3(w, 0.07, d), yaw: 0)
        let node = m.node(material: mats.pbr(.rustedMetal, tiling: 1.4, seed: seed, metalness: 0.7,
                                             tint: NSColor(rgb: 0.16, 0.22, 0.18)), name: "prop")
        node.simdEulerAngles = SIMD3(0, rng.float(0, 2 * .pi), 0)
        return node
    }

    static func barricade(width: Float, seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        // Stacked sandbags and planks — deliberately irregular.
        var y: Float = 0
        var row = 0
        while y < 1.15 {
            var x = -width / 2
            let offset = Float(row % 2) * 0.18
            while x < width / 2 {
                let bw = rng.float(0.34, 0.46)
                m.addPrism(center: SIMD3(x + bw / 2 + offset, y, rng.float(-0.05, 0.05)),
                           radii: (0..<7).map { _ in rng.float(0.16, 0.23) },
                           height: 0.24, topScale: 0.85, yaw: rng.float(0, 2), uvScale: 2.5)
                x += bw
            }
            y += 0.23
            row += 1
        }
        let node = SCNNode()
        node.addChildNode(m.node(material: mats.pbr(.rags(hue: 3), tiling: 3.0, seed: seed)))
        var pm = MeshBuilder()
        for _ in 0..<rng.int(2, 4) {
            pm.addBox(center: SIMD3(rng.float(-width / 3, width / 3), rng.float(0.5, 1.35), rng.float(-0.2, 0.2)),
                      size: SIMD3(rng.float(1.2, 2.4), 0.14, 0.06), yaw: rng.float(-0.5, 0.5))
        }
        node.addChildNode(pm.node(material: mats.pbr(.rottenWood, tiling: 1.6, seed: seed &+ 4)))
        return node
    }

    /// Flat-ish building facade for street backdrops. Windows are dark recesses,
    /// some lit, so a row of these reads as an inhabited (or abandoned) block.
    static func facade(width: Float, height: Float, seed: UInt64, lit: Bool = true) -> SCNNode {
        var rng = Rand(seed: seed)
        let floors = max(Int(height / 3.2), 1)
        let bays = max(Int(width / 2.6), 1)
        var openings: [(x: Float, w: Float, sill: Float, h: Float)] = []
        var glowSpots: [(SIMD3<Float>, Bool)] = []
        for f in 0..<floors {
            for b in 0..<bays {
                let x = -width / 2 + (Float(b) + 0.5) * (width / Float(bays))
                let sill = 0.9 + Float(f) * 3.2
                let w: Float = 1.15, h: Float = 1.7
                openings.append((x, w, sill, h))
                glowSpots.append((SIMD3(x, sill + h / 2, 0), lit && rng.chance(0.22)))
            }
        }
        let node = SCNNode()
        let wallNode = wall(length: width, height: height, thickness: 0.5,
                            kind: rng.chance(0.5) ? .brick : .crackedPlaster,
                            tiling: 0.42, seed: seed, openings: openings)
        node.addChildNode(wallNode)
        // Window interiors: a dark panel just behind the opening, occasionally lit.
        var dm = MeshBuilder()
        for (p, _) in glowSpots {
            dm.addBox(center: SIMD3(p.x, p.y, -0.42), size: SIMD3(1.3, 1.85, 0.08))
        }
        node.addChildNode(dm.node(material: mats.solid(NSColor(rgb: 0.018, 0.016, 0.020), roughness: 0.9)))
        for (p, isLit) in glowSpots where isLit {
            var gm = MeshBuilder()
            gm.addBox(center: SIMD3(p.x, p.y, -0.36), size: SIMD3(1.1, 1.6, 0.04))
            let n = gm.node(material: mats.glow(NSColor(rgb: 0.85, 0.55, 0.22), intensity: 0.85))
            node.addChildNode(n)
        }
        // Cornice
        var cm = MeshBuilder()
        cm.addBox(center: SIMD3(0, height + 0.15, 0), size: SIMD3(width + 0.5, 0.3, 1.0))
        node.addChildNode(cm.node(material: mats.pbr(.concrete, tiling: 0.6, seed: seed &+ 9)))
        return node
    }

    // MARK: - Lab

    static func pipeRun(length: Float, radius: Float, seed: UInt64, count: Int = 3) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        for i in 0..<count {
            let off = Float(i) * (radius * 2.6) - Float(count - 1) * radius * 1.3
            addOrientedTube(&m, from: SIMD3(-length / 2, off, 0), to: SIMD3(length / 2, off, 0),
                            r0: radius, r1: radius, segments: 10)
            // Flanges break up the run so it isn't a featureless cylinder.
            var x = -length / 2 + rng.float(1, 3)
            while x < length / 2 - 0.5 {
                m.addPrism(center: SIMD3(x, off - radius * 1.25, 0),
                           radii: Array(repeating: radius * 1.25, count: 10), height: radius * 0.5,
                           uvScale: 3, capTop: true)
                x += rng.float(2.5, 5)
            }
        }
        // Rotate the prism rings (built around +Y) to lie along +X.
        let node = SCNNode()
        let inner = m.node(material: mats.pbr(.rustedMetal, tiling: 1.6, seed: seed, metalness: 0.85))
        node.addChildNode(inner)
        return node
    }

    static func containmentTank(seed: UInt64, occupied: Bool) -> SCNNode {
        var rng = Rand(seed: seed)
        let node = SCNNode()
        var m = MeshBuilder()
        let h: Float = 2.6, r: Float = 0.62
        m.addPrism(center: SIMD3(0, 0, 0), radii: Array(repeating: r * 1.2, count: 12), height: 0.22, uvScale: 2)
        m.addPrism(center: SIMD3(0, h, 0), radii: Array(repeating: r * 1.2, count: 12), height: 0.28, uvScale: 2)
        for i in 0..<4 {
            let a = Float(i) / 4 * 2 * .pi + 0.4
            m.addTube(base: SIMD3(cos(a) * r * 1.05, 0.2, sin(a) * r * 1.05), height: h - 0.2,
                      bottomRadius: 0.05, topRadius: 0.05, segments: 6)
        }
        node.addChildNode(m.node(material: mats.pbr(.metalPanel, tiling: 1.4, seed: seed, metalness: 0.8)))

        var gm = MeshBuilder()
        gm.addPrism(center: SIMD3(0, 0.22, 0), radii: Array(repeating: r, count: 14), height: h - 0.22,
                    uvScale: 1, capTop: false)
        let glassNode = gm.node(material: mats.glass(tint: NSColor(rgb: 0.16, 0.26, 0.22), opacity: 0.30))
        glassNode.renderingOrder = 20
        node.addChildNode(glassNode)

        // Fluid column, faintly lit from within.
        var fm = MeshBuilder()
        let fluidH = rng.float(1.5, 2.1)
        fm.addPrism(center: SIMD3(0, 0.24, 0), radii: Array(repeating: r * 0.94, count: 14),
                    height: fluidH, uvScale: 1, capTop: true)
        let fluid = fm.node(material: mats.solid(NSColor(rgb: 0.09, 0.22, 0.14), roughness: 0.1,
                                                 emission: NSColor(rgb: 0.06, 0.20, 0.11), emissionIntensity: 0.9))
        node.addChildNode(fluid)
        if occupied {
            // A suspended silhouette. Deliberately vague — detail would break it.
            var bm = MeshBuilder()
            bm.addPrism(center: SIMD3(0, 0.6, 0), radii: (0..<8).map { _ in rng.float(0.13, 0.19) },
                        height: 0.75, topScale: 0.8)
            bm.addPrism(center: SIMD3(0, 1.35, 0), radii: (0..<8).map { _ in rng.float(0.10, 0.13) }, height: 0.24)
            node.addChildNode(bm.node(material: mats.solid(NSColor(rgb: 0.05, 0.07, 0.05), roughness: 0.8)))
        }
        return node
    }

    static func locker(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let w: Float = 0.42, h: Float = 1.85, d: Float = 0.45
        let bays = rng.int(2, 4)
        for i in 0..<bays {
            let x = Float(i) * w - Float(bays - 1) * w / 2
            m.addBox(center: SIMD3(x, h / 2, 0), size: SIMD3(w - 0.012, h, d), uvScale: 1.5)
            if rng.chance(0.35) {
                // Hanging-open door
                let ang = rng.float(0.5, 1.4)
                m.addBox(center: SIMD3(x - w / 2 + sin(ang) * w / 2, h / 2, d / 2 + cos(ang) * w / 2),
                         size: SIMD3(w, h * 0.92, 0.02), yaw: -ang)
            }
        }
        return m.node(material: mats.pbr(.metalPanel, tiling: 1.8, seed: seed, metalness: 0.6,
                                         tint: NSColor(rgb: 0.30, 0.38, 0.36)), name: "prop")
    }

    static func gurney(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        let h: Float = 0.72
        m.addBox(center: SIMD3(0, h, 0), size: SIMD3(0.72, 0.06, 1.95), uvScale: 1.4)
        for sx in [-1, 1] as [Float] {
            for sz in [-1, 1] as [Float] {
                m.addBox(center: SIMD3(sx * 0.3, h / 2, sz * 0.82), size: SIMD3(0.04, h, 0.04))
            }
        }
        m.addBox(center: SIMD3(0, h + 0.22, -0.95), size: SIMD3(0.7, 0.42, 0.04))
        let node = m.node(material: mats.pbr(.metalPanel, tiling: 2.2, seed: seed, metalness: 0.75), name: "prop")
        node.simdEulerAngles = SIMD3(0, rng.float(0, 2 * .pi), 0)
        return node
    }

    // MARK: - Spire

    static func pew(width: Float, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        m.addBox(center: SIMD3(0, 0.44, 0), size: SIMD3(width, 0.07, 0.42), uvScale: 1)
        m.addBox(center: SIMD3(0, 0.72, -0.20), size: SIMD3(width, 0.55, 0.06))
        for s in [-1, 1] as [Float] {
            m.addBox(center: SIMD3(s * (width / 2 - 0.08), 0.22, 0), size: SIMD3(0.08, 0.44, 0.40))
        }
        return m.node(material: mats.pbr(.woodPlank, tiling: 1.2, seed: seed), name: "prop")
    }

    static func statue(seed: UInt64) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        // Robed figure: a tapered mass, shoulders, a bowed head. Reads as a saint
        // in silhouette, which is all it needs to do.
        m.addBox(center: SIMD3(0, 0.18, 0), size: SIMD3(1.0, 0.36, 1.0), uvScale: 1)
        m.addPrism(center: SIMD3(0, 0.36, 0), radii: (0..<9).map { _ in rng.float(0.36, 0.44) },
                   height: 1.35, topScale: 0.62, uvScale: 1)
        m.addPrism(center: SIMD3(0, 1.71, 0), radii: (0..<8).map { _ in rng.float(0.24, 0.29) },
                   height: 0.32, topScale: 0.7, uvScale: 1)
        m.addPrism(center: SIMD3(0, 2.03, 0), radii: Array(repeating: 0.15, count: 8),
                   height: 0.30, topScale: 0.85, topTilt: SIMD2(0, 0.06), uvScale: 1)
        // Arms folded down the front
        for s in [-1, 1] as [Float] {
            Props.addOrientedTube(&m, from: SIMD3(s * 0.24, 1.66, 0.04), to: SIMD3(s * 0.14, 1.05, 0.22),
                                  r0: 0.09, r1: 0.07, segments: 7)
        }
        m.jitter(0.010, seed: seed &+ 3)
        let node = m.node(material: mats.pbr(.marble, tiling: 0.9, seed: seed), name: "prop")
        node.simdEulerAngles = SIMD3(0, rng.float(0, 2 * .pi), 0)
        return node
    }

    static func stainedWindow(width: Float, height: Float, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        m.addQuad(SIMD3(-width / 2, 0, 0), SIMD3(width / 2, 0, 0),
                  SIMD3(width / 2, height, 0), SIMD3(-width / 2, height, 0), uvScale: 0.5)
        let node = SCNNode()
        let glass = m.node(material: mats.pbr(.stainedGlass, tiling: 0.35, seed: seed))
        glass.geometry?.firstMaterial?.emission.intensity = 1.6
        glass.geometry?.firstMaterial?.isDoubleSided = true
        node.addChildNode(glass)
        // Stone tracery around the opening.
        var tm = MeshBuilder()
        tm.addBox(center: SIMD3(0, height / 2, -0.1), size: SIMD3(width + 0.5, 0.22, 0.3))
        tm.addBox(center: SIMD3(0, height, -0.1), size: SIMD3(width + 0.5, 0.25, 0.3))
        tm.addBox(center: SIMD3(0, 0, -0.1), size: SIMD3(width + 0.5, 0.25, 0.3))
        for s in [-1, 1] as [Float] {
            tm.addBox(center: SIMD3(s * width / 2, height / 2, -0.1), size: SIMD3(0.25, height, 0.3))
        }
        node.addChildNode(tm.node(material: mats.pbr(.graniteStone, tiling: 1.0, seed: seed &+ 2)))
        return node
    }

    // MARK: - Scatter helpers

    /// Small rubble/debris field. One merged mesh, so a hundred chunks cost one draw.
    static func rubble(radius: Float, count: Int, seed: UInt64, kind: TextureKind = .gravel) -> SCNNode {
        var rng = Rand(seed: seed)
        var m = MeshBuilder()
        for _ in 0..<count {
            let p = rng.inUnitCircle() * radius
            let s = rng.float(0.06, 0.30)
            m.addPrism(center: SIMD3(p.x, -s * 0.25, p.y),
                       radii: (0..<rng.int(5, 7)).map { _ in s * rng.float(0.7, 1.3) },
                       height: s * rng.float(0.5, 1.1), topScale: rng.float(0.3, 0.8),
                       yaw: rng.float(0, 6.28), uvScale: 3)
        }
        let n = m.node(material: mats.pbr(kind, tiling: 2.0, seed: seed), name: "rubble")
        n.castsShadow = false
        return n
    }

    /// Hanging cables/chains, drooping under gravity.
    static func cableSpan(from a: SIMD3<Float>, to b: SIMD3<Float>, sag: Float, seed: UInt64) -> SCNNode {
        var m = MeshBuilder()
        let steps = 8
        var prev = a
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            var p = simd_mix(a, b, SIMD3(repeating: t))
            p.y -= sin(t * .pi) * sag
            addOrientedTube(&m, from: prev, to: p, r0: 0.022, r1: 0.022, segments: 4)
            prev = p
        }
        let n = m.node(material: mats.pbr(.rustedMetal, tiling: 6, seed: seed, metalness: 0.6), name: "cable")
        n.castsShadow = false
        return n
    }
}
