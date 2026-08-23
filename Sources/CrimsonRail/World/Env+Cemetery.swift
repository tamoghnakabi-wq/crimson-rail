import Foundation
import SceneKit
import AppKit
import simd

extension Environments {

    /// Level 1 — Ashwood Cemetery.
    ///
    /// Lighting brief: a cold moon reads the silhouettes, warm lanterns mark the
    /// route, and the fog line sits just past the furthest spawn so enemies fade
    /// in rather than popping. Everything the player must shoot stands between
    /// those two colour temperatures, which is what keeps it readable.
    static func buildCemetery(_ def: LevelDef, spline: Spline, quality: GraphicsSettings) -> BuiltLevel {
        let root = SCNNode()
        root.name = "level"
        var rng = Rand(seed: def.seed)
        var flickers: [FlickerLight] = []
        let mats = MaterialLibrary.shared

        let centre = spline.position(atDistance: spline.totalLength * 0.5)

        // ---- Ground ---------------------------------------------------------
        let ground = Props.ground(size: 210, kind: .deadGrass, tiling: 0.30,
                                  heightScale: 0.35, divisions: quality.preset == .low ? 24 : 56,
                                  seed: def.seed)
        ground.simdPosition = SIMD3(centre.x, -0.02, centre.z)
        root.addChildNode(ground)

        root.addChildNode(EnvBuild.pathRibbon(spline: spline, width: 3.2, kind: .gravel,
                                              tiling: 0.7, seed: def.seed &+ 1))

        // ---- Graves ---------------------------------------------------------
        // Built into one merged mesh: ~90 stones for a single draw call.
        let graveGroup = SCNNode()
        var graveMesh = MeshBuilder()
        var stoneVariants: [MeshBuilder] = []
        for i in 0..<8 {
            var vm = MeshBuilder()
            buildGravestoneMesh(&vm, seed: def.seed &+ UInt64(i) &* 31)
            stoneVariants.append(vm)
        }
        EnvBuild.scatterAlongRail(spline: spline, step: 2.6, lateralRange: 2.6...26.0, corridor: 2.6,
                                  seed: def.seed &+ 5, density: quality.propDensity * 1.0) { pos, yaw, r, _ in
            graveMesh.append(stoneVariants[r.int(0, stoneVariants.count - 1)],
                             position: SIMD3(pos.x, groundHeight(pos, seed: def.seed), pos.z),
                             yaw: yaw, pitch: r.float(-0.07, 0.07), scale: r.float(0.85, 1.25))
        }
        graveGroup.addChildNode(graveMesh.node(material: mats.pbr(.mossStone, tiling: 3.4, seed: def.seed)))
        root.addChildNode(graveGroup)

        // ---- Trees ----------------------------------------------------------
        let treeGroup = SCNNode()
        EnvBuild.scatterAlongRail(spline: spline, step: 11, lateralRange: 6.0...30.0, corridor: 5.5,
                                  seed: def.seed &+ 9, density: quality.propDensity * 0.75) { pos, _, r, i in
            let t = Props.deadTree(seed: def.seed &+ UInt64(i) &* 17, scale: r.float(0.85, 1.3))
            t.simdPosition = SIMD3(pos.x, groundHeight(pos, seed: def.seed) - 0.15, pos.z)
            treeGroup.addChildNode(t)
        }
        root.addChildNode(EnvBuild.flatten(treeGroup))

        // ---- Perimeter railing ---------------------------------------------
        let fenceGroup = SCNNode()
        var d: Float = 0
        while d < spline.totalLength {
            let p = spline.position(atDistance: d)
            let f = spline.tangent(atDistance: d)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            for side in [-1, 1] as [Float] {
                let seg = Props.ironFence(length: 6.2, seed: def.seed &+ UInt64(d))
                let pos = p + r * (26 * side)
                seg.simdPosition = SIMD3(pos.x, groundHeight(pos, seed: def.seed) - 0.1, pos.z)
                seg.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2, 0)
                fenceGroup.addChildNode(seg)
            }
            d += 6
        }
        root.addChildNode(EnvBuild.flatten(fenceGroup))

        // ---- Entrance arch --------------------------------------------------
        do {
            let arch = SCNNode()
            var m = MeshBuilder()
            for s in [-1, 1] as [Float] {
                m.addBox(center: SIMD3(s * 2.6, 2.1, 0), size: SIMD3(0.75, 4.2, 0.75), uvScale: 1)
                m.addBox(center: SIMD3(s * 2.6, 4.35, 0), size: SIMD3(0.95, 0.3, 0.95))
                m.addPrism(center: SIMD3(s * 2.6, 4.5, 0), radii: Array(repeating: 0.36, count: 4),
                           height: 0.7, topScale: 0.05, yaw: .pi / 4)
            }
            m.addBox(center: SIMD3(0, 4.6, 0), size: SIMD3(5.9, 0.5, 0.55))
            m.addBox(center: SIMD3(0, 5.0, 0), size: SIMD3(3.2, 0.35, 0.45))
            arch.addChildNode(m.node(material: mats.pbr(.graniteStone, tiling: 2.2, seed: def.seed &+ 2)))
            let p = spline.position(atDistance: 2)
            arch.simdPosition = SIMD3(p.x, 0, p.z)
            arch.simdEulerAngles = SIMD3(0, yawToward(spline.tangent(atDistance: 2)), 0)
            root.addChildNode(arch)
        }

        // ---- Mausoleums -----------------------------------------------------
        for (i, dist) in [30, 62, 95].enumerated() {
            let maus = Props.mausoleum(seed: def.seed &+ UInt64(i) &* 41)
            let p = spline.position(atDistance: Float(dist))
            let f = spline.tangent(atDistance: Float(dist))
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let side: Float = i % 2 == 0 ? -1 : 1
            let pos = p + r * (11.5 * side)
            maus.simdPosition = SIMD3(pos.x, groundHeight(pos, seed: def.seed), pos.z)
            maus.simdEulerAngles = SIMD3(0, yawToward(f) + (side > 0 ? -.pi / 2 : .pi / 2), 0)
            root.addChildNode(maus)
        }

        // ---- The chapel at the end -----------------------------------------
        do {
            let chapel = SCNNode()
            let endD = spline.totalLength
            let p = spline.position(atDistance: endD)
            let f = spline.tangent(atDistance: endD)

            var m = MeshBuilder()
            // Body, with the doorway punched out of the near wall.
            m.addBox(center: SIMD3(0, 4.0, 7.0), size: SIMD3(13, 8, 14), uvScale: 1,
                     faces: [.left, .right, .back, .top])
            let doorW: Float = 2.2, doorH: Float = 3.4
            let side = (13 - doorW) / 2
            m.addBox(center: SIMD3(-(doorW / 2 + side / 2), 4.0, 0), size: SIMD3(side, 8, 0.6), uvScale: 1)
            m.addBox(center: SIMD3(doorW / 2 + side / 2, 4.0, 0), size: SIMD3(side, 8, 0.6), uvScale: 1)
            m.addBox(center: SIMD3(0, doorH + (8 - doorH) / 2, 0), size: SIMD3(doorW, 8 - doorH, 0.6), uvScale: 1)
            // Gable and steeple.
            m.addPrism(center: SIMD3(0, 8, 7.0), radii: [7.4, 7.4, 7.4], height: 3.4, topScale: 0.04, yaw: 0, uvScale: 1)
            m.addBox(center: SIMD3(0, 9.6, 2.2), size: SIMD3(3.0, 3.2, 3.0), uvScale: 1)
            m.addPrism(center: SIMD3(0, 11.2, 2.2), radii: Array(repeating: 2.1, count: 4),
                       height: 4.2, topScale: 0.03, yaw: .pi / 4, uvScale: 1)
            chapel.addChildNode(m.node(material: mats.pbr(.graniteStone, tiling: 1.3, seed: def.seed &+ 3)))

            // Interior glow behind the door, so the goal reads as a destination.
            let inner = SCNNode(geometry: SCNPlane(width: 2.2, height: 3.4))
            inner.geometry?.materials = [mats.glow(NSColor(rgb: 0.95, 0.55, 0.20), intensity: 0.55)]
            inner.simdPosition = SIMD3(0, 1.7, 0.5)
            chapel.addChildNode(inner)

            let doorLight = EnvBuild.lamp(color: NSColor.Pal.candle, intensity: 900, range: 22,
                                          castsShadow: quality.maxShadowCastingLights > 1, quality: quality)
            doorLight.simdPosition = SIMD3(0, 2.6, 1.6)
            chapel.addChildNode(doorLight)
            flickers.append(FlickerLight(node: doorLight, baseIntensity: 900, speed: 2.6,
                                         depth: 0.18, isFailing: false, seed: 3.1))

            // Rose window above the door.
            let rose = Props.stainedWindow(width: 3.0, height: 3.0, seed: def.seed &+ 77)
            rose.simdPosition = SIMD3(0, 4.4, 0.1)
            chapel.addChildNode(rose)

            chapel.simdPosition = SIMD3(p.x, 0, p.z)
            chapel.simdEulerAngles = SIMD3(0, yawToward(f) + .pi, 0)
            root.addChildNode(chapel)
        }

        // ---- Rubble and ground clutter -------------------------------------
        let clutter = SCNNode()
        EnvBuild.scatterAlongRail(spline: spline, step: 7, lateralRange: 2.2...16.0, corridor: 2.2,
                                  seed: def.seed &+ 13, density: quality.propDensity * 0.6) { pos, _, r, _ in
            let n = Props.rubble(radius: r.float(0.6, 1.4), count: r.int(4, 10),
                                 seed: UInt64(r.int(1, 9999)), kind: .gravel)
            n.simdPosition = SIMD3(pos.x, groundHeight(pos, seed: def.seed), pos.z)
            clutter.addChildNode(n)
        }
        root.addChildNode(EnvBuild.flatten(clutter, castsShadow: false))

        // ---- Lanterns along the path ---------------------------------------
        var lanternDist: Float = 12
        while lanternDist < spline.totalLength - 8 {
            let p = spline.position(atDistance: lanternDist)
            let f = spline.tangent(atDistance: lanternDist)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let side: Float = rng.chance(0.5) ? -1 : 1
            let pos = p + r * (2.6 * side)

            let post = SCNNode()
            var m = MeshBuilder()
            m.addTube(base: .zero, height: 2.5, bottomRadius: 0.06, topRadius: 0.045, segments: 6)
            m.addBox(center: SIMD3(0, 2.72, 0), size: SIMD3(0.30, 0.34, 0.30))
            m.addPrism(center: SIMD3(0, 2.89, 0), radii: Array(repeating: 0.23, count: 4),
                       height: 0.20, topScale: 0.1, yaw: .pi / 4)
            post.addChildNode(m.node(material: mats.pbr(.rustedMetal, tiling: 4, seed: def.seed, metalness: 0.8)))

            let flame = EnvBuild.practicalLight(color: NSColor.Pal.candle, intensity: 420, range: 20,
                                                bulbRadius: 0.075,
                                                castsShadow: quality.maxShadowCastingLights > 2,
                                                quality: quality)
            flame.simdPosition = SIMD3(0, 2.72, 0)
            post.addChildNode(flame)
            flickers.append(FlickerLight(node: flame, baseIntensity: 420, speed: rng.float(3.0, 5.5),
                                         depth: 0.26, isFailing: false, seed: rng.float(0, 10)))

            post.simdPosition = SIMD3(pos.x, groundHeight(pos, seed: def.seed), pos.z)
            root.addChildNode(post)
            lanternDist += rng.float(19, 27)
        }

        // ---- Key lighting ---------------------------------------------------
        let moon = SCNNode()
        let moonLight = SCNLight()
        moonLight.type = .directional
        moonLight.color = NSColor.Pal.moonlight
        moonLight.intensity = 1450
        let moonDir = simd_normalize(SIMD3<Float>(0.55, -0.72, 0.42))
        EnvBuild.configureKeyShadow(moonLight, quality: quality, range: 34)
        moonLight.shadowColor = NSColor(white: 0, alpha: 0.66)
        moon.light = moonLight
        moon.simdOrientation = lookRotation(forward: moonDir)
        root.addChildNode(moon)

        let ambient = SCNNode()
        let amb = SCNLight()
        amb.type = .ambient
        amb.color = NSColor(rgb: 0.17, 0.22, 0.34)
        amb.intensity = 245
        ambient.light = amb
        root.addChildNode(ambient)

        // Low fill from behind, so silhouettes separate from the fog.
        let rim = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.color = NSColor(rgb: 0.30, 0.40, 0.62)
        rimLight.intensity = 330
        rimLight.castsShadow = false
        rim.light = rimLight
        rim.simdOrientation = lookRotation(forward: simd_normalize(SIMD3(-0.4, -0.25, -0.85)))
        root.addChildNode(rim)

        // ---- Atmosphere -----------------------------------------------------
        let mist = groundMist(spline: spline, quality: quality, seed: def.seed,
                              color: NSColor(rgb: 0.55, 0.62, 0.75))
        root.addChildNode(mist)

        return BuiltLevel(
            root: root,
            spline: spline,
            fogColor: NSColor(rgb: 0.045, 0.058, 0.085),
            fogStart: 14,
            fogEnd: min(quality.drawDistance, 78),
            fogDensityExponent: 1.7,
            background: NSColor(rgb: 0.020, 0.026, 0.042),
            flickerLights: flickers,
            ambience: .wind,
            corridorHalfWidth: 15,
            groundHeight: { p in Environments.groundHeight(p, seed: def.seed) },
            keyLightNode: moon,
            keyLightDirection: moonDir,
            keyLightRange: 34,
            weaponLightColor: NSColor(rgb: 1.0, 0.95, 0.90),
            weaponLightIntensity: 620)
    }

    // MARK: Helpers

    /// Matches the displacement used by `Props.ground` so props sit on the surface
    /// instead of hovering or sinking.
    static func groundHeight(_ p: SIMD3<Float>, seed: UInt64) -> Float {
        let n = Noise.fbm(p.x * 0.045, p.z * 0.045, octaves: 4, period: 16, seed: seed)
        let fine = Noise.fbm(p.x * 0.22, p.z * 0.22, octaves: 3, period: 32, seed: seed &+ 7)
        return (n - 0.5) * 0.35 * 2 + (fine - 0.5) * 0.35 * 0.5 - 0.02
    }

    static func buildGravestoneMesh(_ m: inout MeshBuilder, seed: UInt64) {
        var rng = Rand(seed: seed)
        let style = rng.int(0, 3)
        let w = rng.float(0.5, 0.85), t = rng.float(0.11, 0.18), h = rng.float(0.7, 1.5)
        switch style {
        case 0:
            m.addBox(center: SIMD3(0, h / 2, 0), size: SIMD3(w, h, t), uvScale: 1)
            m.addBox(center: SIMD3(0, h + 0.05, 0), size: SIMD3(w * 0.82, 0.10, t * 0.98), uvScale: 1)
            m.addBox(center: SIMD3(0, h + 0.13, 0), size: SIMD3(w * 0.55, 0.08, t * 0.96), uvScale: 1)
        case 1:
            m.addBox(center: SIMD3(0, h / 2, 0), size: SIMD3(w * 0.28, h, t), uvScale: 1)
            m.addBox(center: SIMD3(0, h * 0.74, 0), size: SIMD3(w, w * 0.26, t * 0.98), uvScale: 1)
            m.addBox(center: SIMD3(0, 0.06, 0), size: SIMD3(w * 1.1, 0.12, t * 2.2), uvScale: 1)
        case 2:
            let base = h * 1.3
            m.addBox(center: SIMD3(0, 0.09, 0), size: SIMD3(w * 1.3, 0.18, w * 1.3), uvScale: 1)
            m.addPrism(center: SIMD3(0, 0.18, 0), radii: Array(repeating: w * 0.42, count: 4),
                       height: base, topScale: 0.62, yaw: .pi / 4, uvScale: 1)
            m.addPrism(center: SIMD3(0, 0.18 + base, 0), radii: Array(repeating: w * 0.26, count: 4),
                       height: w * 0.55, topScale: 0.02, yaw: .pi / 4, uvScale: 1)
        default:
            m.addBox(center: SIMD3(0, h * 0.28, 0), size: SIMD3(w, h * 0.56, t), uvScale: 1)
            m.addBox(center: SIMD3(rng.float(-0.1, 0.1), h * 0.6, 0),
                     size: SIMD3(w * 0.6, h * 0.18, t), yaw: rng.float(-0.3, 0.3), uvScale: 1)
        }
        m.jitter(0.010, seed: seed &+ 5)
    }

    /// Low-lying fog banks. A handful of wide, very slow particle emitters reads
    /// far better than global fog alone and costs almost nothing.
    static func groundMist(spline: Spline, quality: GraphicsSettings, seed: UInt64,
                           color: NSColor, height: Float = 0.35) -> SCNNode {
        let group = SCNNode()
        guard quality.particleBudget > 0.4 else { return group }
        var d: Float = 6
        var rng = Rand(seed: seed &+ 555)
        while d < spline.totalLength {
            let p = spline.position(atDistance: d)
            let ps = SCNParticleSystem()
            ps.birthRate = CGFloat(3 * quality.particleBudget)
            ps.particleLifeSpan = 16
            ps.particleLifeSpanVariation = 6
            ps.particleSize = 5.0
            ps.particleSizeVariation = 3.0
            ps.particleColor = color.withAlphaComponent(0.055)
            ps.particleColorVariation = SCNVector4(0.02, 0.02, 0.04, 0.02)
            ps.particleImage = MaterialLibrary.softDot
            ps.blendMode = .alpha
            ps.emitterShape = SCNBox(width: 16, height: 0.2, length: 16, chamferRadius: 0)
            ps.birthLocation = .volume
            ps.particleVelocity = 0.16
            ps.particleVelocityVariation = 0.12
            ps.spreadingAngle = 90
            ps.acceleration = SCNVector3(0.02, 0.002, 0)
            ps.isAffectedByGravity = false
            ps.particleAngleVariation = 180
            ps.particleAngularVelocity = 1.5
            ps.particleAngularVelocityVariation = 3
            ps.isLightingEnabled = false
            ps.sortingMode = .distance
            ps.orientationMode = .billboardScreenAligned
            let n = SCNNode()
            n.addParticleSystem(ps)
            n.simdPosition = SIMD3(p.x + rng.float(-2, 2), height, p.z + rng.float(-2, 2))
            n.castsShadow = false
            group.addChildNode(n)
            d += 18
        }
        return group
    }
}
