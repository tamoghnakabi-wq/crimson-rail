import Foundation
import SceneKit
import AppKit
import simd

extension Environments {

    /// Level 2 — Ashwood Manor.
    ///
    /// An interior, so there is no key light at all: every scrap of illumination
    /// is a candle the player can see. That is what makes the weapon light matter
    /// here, and why the corridors read as claustrophobic rather than merely dark.
    static func buildManor(_ def: LevelDef, spline: Spline, quality: GraphicsSettings) -> BuiltLevel {
        let root = SCNNode()
        root.name = "level"
        var rng = Rand(seed: def.seed)
        var flickers: [FlickerLight] = []
        let mats = MaterialLibrary.shared
        let ground = EnvBuild.railHeightField(spline: spline)

        let corridorHalf: Float = 4.2
        let ceilingHeight: Float = 4.0

        // ---- Floor, walls and ceiling ---------------------------------------
        root.addChildNode(EnvBuild.pathRibbon(spline: spline, width: corridorHalf * 2,
                                              kind: .woodPlank, tiling: 0.5, seed: def.seed, yOffset: 0))

        let shell = SCNNode()
        var d: Float = 0
        var bayIndex = 0
        while d < spline.totalLength {
            let p = spline.position(atDistance: d)
            let f = spline.tangent(atDistance: d)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let segLen: Float = 4.0

            for side in [-1, 1] as [Float] {
                // Every few bays the wall is broken by a tall doorway, so the run
                // does not read as one endless painted plane.
                let openings: [(x: Float, w: Float, sill: Float, h: Float)] =
                    (bayIndex % 3 == 0) ? [(0, 1.6, 0, 2.7)] : []
                let w = Props.wall(length: segLen + 0.1, height: ceilingHeight, thickness: 0.34,
                                   kind: .wallpaper, tiling: 0.55, seed: def.seed &+ UInt64(bayIndex),
                                   openings: openings)
                let pos = p + r * (corridorHalf * side)
                w.simdPosition = SIMD3(pos.x, p.y, pos.z)
                w.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2, 0)
                shell.addChildNode(w)

                // Dado rail and skirting: the detail that stops a flat wall
                // reading as a flat wall.
                var trim = MeshBuilder()
                trim.addBox(center: SIMD3(0, 0.95, 0), size: SIMD3(segLen + 0.1, 0.09, 0.42))
                trim.addBox(center: SIMD3(0, 0.12, 0), size: SIMD3(segLen + 0.1, 0.24, 0.44))
                let t = trim.node(material: mats.pbr(.rottenWood, tiling: 1.6, seed: def.seed &+ 2))
                t.simdPosition = SIMD3(pos.x, p.y, pos.z)
                t.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2, 0)
                shell.addChildNode(t)
            }

            // Ceiling panel with a beam.
            var ceil = MeshBuilder()
            ceil.addQuad(SIMD3(-corridorHalf, ceilingHeight, segLen / 2),
                         SIMD3(corridorHalf, ceilingHeight, segLen / 2),
                         SIMD3(corridorHalf, ceilingHeight, -segLen / 2),
                         SIMD3(-corridorHalf, ceilingHeight, -segLen / 2),
                         uvScale: 1, normal: SIMD3(0, -1, 0))
            ceil.addBox(center: SIMD3(0, ceilingHeight - 0.14, 0),
                        size: SIMD3(corridorHalf * 2, 0.28, 0.30))
            let c = ceil.node(material: mats.pbr(.rottenWood, tiling: 0.5, seed: def.seed &+ 3))
            c.simdPosition = SIMD3(p.x, p.y, p.z)
            c.simdEulerAngles = SIMD3(0, yawToward(f), 0)
            c.castsShadow = false
            shell.addChildNode(c)

            d += segLen
            bayIndex += 1
        }
        root.addChildNode(EnvBuild.flatten(shell))

        // ---- Furniture and dressing -----------------------------------------
        let dressing = SCNNode()
        EnvBuild.scatterAlongRail(spline: spline, step: 5.5, lateralRange: 2.5...3.7, corridor: 2.5,
                                  seed: def.seed &+ 11, density: quality.propDensity * 0.85) { pos, yaw, r, i in
            let y = ground(pos)
            let node: SCNNode
            switch r.int(0, 4) {
            case 0: node = Props.bookshelf(seed: def.seed &+ UInt64(i))
            case 1: node = Props.table(width: r.float(1.1, 1.8), depth: 0.8, seed: def.seed &+ UInt64(i))
            case 2: node = Props.chair(seed: def.seed &+ UInt64(i), toppled: r.chance(0.55))
            case 3: node = Props.locker(seed: def.seed &+ UInt64(i))
            default: node = Props.table(width: 0.7, depth: 0.7, height: 0.62, seed: def.seed &+ UInt64(i))
            }
            node.simdPosition = SIMD3(pos.x, y, pos.z)
            node.simdEulerAngles = SIMD3(0, yaw, 0)
            dressing.addChildNode(node)
        }
        root.addChildNode(EnvBuild.flatten(dressing))

        // Portraits, hung at eye level along the walls.
        let art = SCNNode()
        var pd: Float = 6
        while pd < spline.totalLength - 4 {
            let p = spline.position(atDistance: pd)
            let f = spline.tangent(atDistance: pd)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let side: Float = rng.chance(0.5) ? -1 : 1
            let portrait = Props.portrait(seed: def.seed &+ UInt64(pd))
            let pos = p + r * ((corridorHalf - 0.22) * side)
            portrait.simdPosition = SIMD3(pos.x, p.y + 2.05, pos.z)
            portrait.simdEulerAngles = SIMD3(0, yawToward(f) + (side > 0 ? -.pi / 2 : .pi / 2), 0)
            art.addChildNode(portrait)
            pd += rng.float(5.5, 9.5)
        }
        root.addChildNode(EnvBuild.flatten(art))

        // ---- Lighting: candles only -----------------------------------------
        var lightD: Float = 5
        while lightD < spline.totalLength {
            let p = spline.position(atDistance: lightD)
            let f = spline.tangent(atDistance: lightD)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))

            if rng.chance(0.45) {
                // Chandelier over the middle of the corridor.
                let ch = Props.chandelier(seed: def.seed &+ UInt64(lightD))
                ch.simdPosition = SIMD3(p.x, p.y + ceilingHeight - 0.35, p.z)
                root.addChildNode(ch)
                let l = EnvBuild.lamp(color: NSColor.Pal.candle, intensity: 340, range: 13,
                                      castsShadow: quality.maxShadowCastingLights > 1, quality: quality)
                l.simdPosition = SIMD3(p.x, p.y + ceilingHeight - 0.75, p.z)
                root.addChildNode(l)
                flickers.append(FlickerLight(node: l, baseIntensity: 340, speed: rng.float(3.5, 6.5),
                                             depth: 0.30, isFailing: false, seed: rng.float(0, 10)))
            } else {
                // Wall sconce.
                let side: Float = rng.chance(0.5) ? -1 : 1
                let pos = p + r * ((corridorHalf - 0.3) * side)
                var m = MeshBuilder()
                m.addBox(center: .zero, size: SIMD3(0.10, 0.26, 0.10))
                Props.addOrientedTube(&m, from: SIMD3(0, 0.1, 0), to: SIMD3(0, 0.30, -0.18 * side),
                                      r0: 0.03, r1: 0.035, segments: 6)
                let sconce = m.node(material: mats.pbr(.rustedMetal, tiling: 6, seed: def.seed, metalness: 0.8))
                sconce.simdPosition = SIMD3(pos.x, p.y + 2.35, pos.z)
                root.addChildNode(sconce)

                let l = EnvBuild.practicalLight(color: NSColor.Pal.candle, intensity: 210, range: 9.5,
                                                bulbRadius: 0.05, castsShadow: false, quality: quality)
                l.simdPosition = SIMD3(pos.x, p.y + 2.62, pos.z)
                root.addChildNode(l)
                flickers.append(FlickerLight(node: l, baseIntensity: 210, speed: rng.float(4, 8),
                                             depth: 0.38, isFailing: false, seed: rng.float(0, 10)))
            }
            lightD += rng.float(7.5, 12)
        }

        // Very low ambient: an interior with no windows has almost no bounce.
        let ambient = SCNNode()
        let amb = SCNLight()
        amb.type = .ambient
        amb.color = NSColor(rgb: 0.26, 0.20, 0.15)
        amb.intensity = 95
        ambient.light = amb
        root.addChildNode(ambient)

        // Dust motes in the air, catching the candlelight.
        if quality.particleBudget > 0.4 {
            root.addChildNode(groundMist(spline: spline, quality: quality, seed: def.seed,
                                         color: NSColor(rgb: 0.75, 0.62, 0.45), height: 1.4))
        }

        return BuiltLevel(
            root: root,
            spline: spline,
            fogColor: NSColor(rgb: 0.028, 0.022, 0.017),
            fogStart: 8,
            fogEnd: min(quality.drawDistance, 44),
            fogDensityExponent: 1.5,
            background: NSColor(rgb: 0.012, 0.010, 0.008),
            flickerLights: flickers,
            ambience: .interior,
            corridorHalfWidth: corridorHalf - 0.5,
            groundHeight: ground,
            weaponLightColor: NSColor(rgb: 1.0, 0.93, 0.82),
            weaponLightIntensity: 780)
    }
}
