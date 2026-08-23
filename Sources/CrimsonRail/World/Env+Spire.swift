import Foundation
import SceneKit
import AppKit
import simd

extension Environments {

    /// Level 5 — Ashwood Spire.
    ///
    /// A cathedral nave that climbs eight metres to the boss floor. Stained glass
    /// carries the colour, candles carry the warmth, and the storm outside throws
    /// periodic lightning through the windows — the only time the whole space is
    /// visible at once.
    static func buildSpire(_ def: LevelDef, spline: Spline, quality: GraphicsSettings) -> BuiltLevel {
        let root = SCNNode()
        root.name = "level"
        var rng = Rand(seed: def.seed)
        var flickers: [FlickerLight] = []
        let mats = MaterialLibrary.shared
        let ground = EnvBuild.railHeightField(spline: spline)

        let half: Float = 6.5
        let wallHeight: Float = 11.0

        root.addChildNode(EnvBuild.pathRibbon(spline: spline, width: half * 2,
                                              kind: .graniteStone, tiling: 1.15, seed: def.seed &+ 31, yOffset: 0))

        // ---- Nave walls, buttresses and windows ---------------------------------
        let shell = SCNNode()
        var d: Float = 0
        var bay = 0
        while d < spline.totalLength {
            let p = spline.position(atDistance: d)
            let f = spline.tangent(atDistance: d)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let segLen: Float = 5.0

            for side in [-1, 1] as [Float] {
                let hasWindow = bay % 2 == 0
                let openings: [(x: Float, w: Float, sill: Float, h: Float)] =
                    hasWindow ? [(0, 2.6, 3.4, 5.2)] : []
                let w = Props.wall(length: segLen + 0.1, height: wallHeight, thickness: 0.5,
                                   kind: .graniteStone, tiling: 0.35, seed: def.seed &+ UInt64(bay),
                                   openings: openings)
                let pos = p + r * (half * side)
                w.simdPosition = SIMD3(pos.x, p.y, pos.z)
                w.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2, 0)
                shell.addChildNode(w)

                if hasWindow {
                    let win = Props.stainedWindow(width: 2.5, height: 5.1, seed: def.seed &+ UInt64(bay))
                    let wp = p + r * ((half - 0.24) * side)
                    win.simdPosition = SIMD3(wp.x, p.y + 3.45, wp.z)
                    win.simdEulerAngles = SIMD3(0, yawToward(f) + (side > 0 ? -.pi / 2 : .pi / 2), 0)
                    root.addChildNode(win)

                    // Light spilling in through the glass.
                    let l = EnvBuild.lamp(color: NSColor(rgb: 0.45, 0.55, 0.85), intensity: 170, range: 17,
                                          castsShadow: false, quality: quality)
                    l.simdPosition = SIMD3(wp.x, p.y + 5.0, wp.z)
                    root.addChildNode(l)
                    flickers.append(FlickerLight(node: l, baseIntensity: 170, speed: 0.7,
                                                 depth: 0.25, isFailing: false, seed: rng.float(0, 10)))
                }

                // Column against the wall.
                let col = Props.column(height: wallHeight * 0.8, radius: 0.34,
                                       kind: .graniteStone, seed: def.seed &+ UInt64(bay))
                let cp = p + r * ((half - 0.7) * side)
                col.simdPosition = SIMD3(cp.x, p.y, cp.z)
                shell.addChildNode(col)
            }
            d += segLen
            bay += 1
        }
        root.addChildNode(EnvBuild.flatten(shell))

        // ---- Pews in the lower nave ----------------------------------------------
        let pews = SCNNode()
        var pd: Float = 8
        while pd < spline.totalLength * 0.45 {
            let p = spline.position(atDistance: pd)
            let f = spline.tangent(atDistance: pd)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            for side in [-1, 1] as [Float] {
                let pew = Props.pew(width: 3.4, seed: def.seed &+ UInt64(pd))
                let pos = p + r * (3.6 * side)
                pew.simdPosition = SIMD3(pos.x, ground(pos), pos.z)
                pew.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2 + rng.float(-0.12, 0.12), 0)
                pews.addChildNode(pew)
            }
            pd += 2.4
        }
        root.addChildNode(EnvBuild.flatten(pews))

        // ---- Statues and candles along the route ---------------------------------
        let saints = SCNNode()
        EnvBuild.scatterAlongRail(spline: spline, step: 11, lateralRange: 4.3...5.4, corridor: 4.3,
                                  seed: def.seed &+ 23, density: quality.propDensity * 0.85) { pos, _, r, i in
            let s = Props.statue(seed: def.seed &+ UInt64(i))
            s.simdPosition = SIMD3(pos.x, ground(pos), pos.z)
            saints.addChildNode(s)
            _ = r
        }
        root.addChildNode(EnvBuild.flatten(saints))

        var cd: Float = 5
        while cd < spline.totalLength {
            let p = spline.position(atDistance: cd)
            let f = spline.tangent(atDistance: cd)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let side: Float = rng.chance(0.5) ? -1 : 1
            let pos = p + r * (3.1 * side)

            // Candle rack.
            let rack = SCNNode()
            var m = MeshBuilder()
            m.addBox(center: SIMD3(0, 0.45, 0), size: SIMD3(0.9, 0.06, 0.28))
            for s in [-1, 1] as [Float] {
                m.addBox(center: SIMD3(s * 0.38, 0.22, 0), size: SIMD3(0.06, 0.45, 0.06))
            }
            rack.addChildNode(m.node(material: mats.pbr(.rustedMetal, tiling: 5, seed: def.seed, metalness: 0.8)))
            for k in 0..<5 {
                let x = (Float(k) - 2) * 0.17
                let flame = SCNNode(geometry: SCNSphere(radius: 0.03))
                flame.geometry?.materials = [mats.glow(NSColor.Pal.candle, intensity: 3.0)]
                flame.simdPosition = SIMD3(x, 0.56, 0)
                flame.castsShadow = false
                rack.addChildNode(flame)
            }
            rack.simdPosition = SIMD3(pos.x, ground(pos), pos.z)
            root.addChildNode(rack)

            let l = EnvBuild.lamp(color: NSColor.Pal.candle, intensity: 155, range: 12,
                                  castsShadow: quality.maxShadowCastingLights > 3, quality: quality)
            l.simdPosition = SIMD3(pos.x, ground(pos) + 0.7, pos.z)
            root.addChildNode(l)
            flickers.append(FlickerLight(node: l, baseIntensity: 155, speed: rng.float(4, 8),
                                         depth: 0.35, isFailing: false, seed: rng.float(0, 10)))
            cd += rng.float(8, 14)
        }

        // ---- Steps where the rail climbs ------------------------------------------
        let steps = SCNNode()
        var sd: Float = 0
        while sd < spline.totalLength - 3 {
            let a = spline.position(atDistance: sd)
            let b = spline.position(atDistance: sd + 3)
            if b.y - a.y > 0.25 {
                let f = spline.tangent(atDistance: sd)
                let flight = Props.stairs(steps: 6, width: half * 1.8,
                                          rise: (b.y - a.y) / 6, run: 3.0 / 6,
                                          kind: .graniteStone, seed: def.seed &+ UInt64(sd))
                flight.simdPosition = SIMD3(a.x, a.y, a.z)
                flight.simdEulerAngles = SIMD3(0, yawToward(f), 0)
                steps.addChildNode(flight)
            }
            sd += 3
        }
        root.addChildNode(EnvBuild.flatten(steps))

        // ---- The altar at the summit ----------------------------------------------
        do {
            let end = spline.totalLength
            let p = spline.position(atDistance: end)
            let f = spline.tangent(atDistance: end)
            let altar = SCNNode()
            var m = MeshBuilder()
            m.addBox(center: SIMD3(0, 0.10, 0), size: SIMD3(4.4, 0.20, 2.6), uvScale: 1)
            m.addBox(center: SIMD3(0, 0.62, 0), size: SIMD3(3.2, 0.85, 1.5), uvScale: 1)
            m.addBox(center: SIMD3(0, 1.10, 0), size: SIMD3(3.6, 0.12, 1.8), uvScale: 1)
            altar.addChildNode(m.node(material: mats.pbr(.marble, tiling: 0.8, seed: def.seed &+ 41)))

            let window = Props.stainedWindow(width: 5.0, height: 8.0, seed: def.seed &+ 99)
            window.simdPosition = SIMD3(0, 2.2, 3.4)
            altar.addChildNode(window)

            let glow = EnvBuild.lamp(color: NSColor(rgb: 0.75, 0.35, 0.95), intensity: 700, range: 24,
                                     castsShadow: false, quality: quality)
            glow.simdPosition = SIMD3(0, 4.5, 2.6)
            altar.addChildNode(glow)
            flickers.append(FlickerLight(node: glow, baseIntensity: 700, speed: 1.1,
                                         depth: 0.2, isFailing: false, seed: 4.4))

            altar.simdPosition = SIMD3(p.x, p.y, p.z)
            altar.simdEulerAngles = SIMD3(0, yawToward(f), 0)
            root.addChildNode(altar)
        }

        // ---- Storm key light ---------------------------------------------------
        let key = SCNNode()
        let kl = SCNLight()
        kl.type = .directional
        kl.color = NSColor(rgb: 0.52, 0.62, 0.92)
        kl.intensity = 400
        let dir = simd_normalize(SIMD3<Float>(0.42, -0.78, 0.46))
        EnvBuild.configureKeyShadow(kl, quality: quality, range: 34)
        kl.shadowColor = NSColor(white: 0, alpha: 0.6)
        key.light = kl
        key.simdOrientation = lookRotation(forward: dir)
        root.addChildNode(key)
        // The storm itself: rare, hard, brief brightening of the whole space.
        flickers.append(FlickerLight(node: key, baseIntensity: 620, speed: 0.55,
                                     depth: 0.7, isFailing: true, seed: 1.7))

        let ambient = SCNNode()
        let amb = SCNLight()
        amb.type = .ambient
        amb.color = NSColor(rgb: 0.20, 0.21, 0.30)
        amb.intensity = 105
        ambient.light = amb
        root.addChildNode(ambient)

        root.addChildNode(groundMist(spline: spline, quality: quality, seed: def.seed,
                                     color: NSColor(rgb: 0.55, 0.58, 0.75), height: 0.5))

        return BuiltLevel(
            root: root,
            spline: spline,
            fogColor: NSColor(rgb: 0.030, 0.033, 0.048),
            fogStart: 12,
            fogEnd: min(quality.drawDistance, 66),
            fogDensityExponent: 1.6,
            background: NSColor(rgb: 0.014, 0.016, 0.026),
            flickerLights: flickers,
            ambience: .storm,
            corridorHalfWidth: half - 0.6,
            groundHeight: ground,
            keyLightNode: key,
            keyLightDirection: dir,
            keyLightRange: 34,
            weaponLightColor: NSColor(rgb: 1.0, 0.95, 0.88),
            weaponLightIntensity: 480)
    }
}
