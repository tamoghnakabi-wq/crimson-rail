import Foundation
import SceneKit
import AppKit
import simd

extension Environments {

    /// Level 4 — Sublevel Seven.
    ///
    /// Cold and institutional: white-green fluorescents that fail in bursts, red
    /// emergency strips that never do, and containment glass lit from within. The
    /// failing tubes are the point — the level keeps taking its own lighting away.
    static func buildLab(_ def: LevelDef, spline: Spline, quality: GraphicsSettings) -> BuiltLevel {
        let root = SCNNode()
        root.name = "level"
        var rng = Rand(seed: def.seed)
        var flickers: [FlickerLight] = []
        let mats = MaterialLibrary.shared
        let ground = EnvBuild.railHeightField(spline: spline)

        let half: Float = 4.6
        let ceilingHeight: Float = 3.5

        root.addChildNode(EnvBuild.pathRibbon(spline: spline, width: half * 2,
                                              kind: .labTile, tiling: 0.85, seed: def.seed, yOffset: 0))

        // ---- Shell ------------------------------------------------------------
        let shell = SCNNode()
        var d: Float = 0
        var bay = 0
        while d < spline.totalLength {
            let p = spline.position(atDistance: d)
            let f = spline.tangent(atDistance: d)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let segLen: Float = 4.0

            for side in [-1, 1] as [Float] {
                // Observation windows every third bay, so the corridor has depth
                // beyond its own walls.
                let openings: [(x: Float, w: Float, sill: Float, h: Float)] =
                    (bay % 3 == 1) ? [(0, 2.4, 1.1, 1.5)] : []
                let w = Props.wall(length: segLen + 0.1, height: ceilingHeight, thickness: 0.30,
                                   kind: .metalPanel, tiling: 0.85, seed: def.seed &+ UInt64(bay),
                                   openings: openings)
                let pos = p + r * (half * side)
                w.simdPosition = SIMD3(pos.x, p.y, pos.z)
                w.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2, 0)
                shell.addChildNode(w)

                // Hazard stripe at knee height.
                var stripe = MeshBuilder()
                stripe.addBox(center: SIMD3(0, 0.55, 0), size: SIMD3(segLen + 0.1, 0.14, 0.34))
                let sn = stripe.node(material: mats.solid(NSColor.Pal.hazard, roughness: 0.6))
                sn.simdPosition = SIMD3(pos.x, p.y, pos.z)
                sn.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2, 0)
                shell.addChildNode(sn)
            }

            var ceil = MeshBuilder()
            ceil.addQuad(SIMD3(-half, ceilingHeight, segLen / 2), SIMD3(half, ceilingHeight, segLen / 2),
                         SIMD3(half, ceilingHeight, -segLen / 2), SIMD3(-half, ceilingHeight, -segLen / 2),
                         uvScale: 1, normal: SIMD3(0, -1, 0))
            let c = ceil.node(material: mats.pbr(.metalPanel, tiling: 0.5, seed: def.seed &+ 5))
            c.simdPosition = SIMD3(p.x, p.y, p.z)
            c.simdEulerAngles = SIMD3(0, yawToward(f), 0)
            c.castsShadow = false
            shell.addChildNode(c)

            d += segLen
            bay += 1
        }
        root.addChildNode(EnvBuild.flatten(shell))

        // ---- Pipes and cabling along the ceiling line --------------------------
        let services = SCNNode()
        var sd: Float = 2
        while sd < spline.totalLength - 4 {
            let p0 = spline.position(atDistance: sd)
            let p1 = spline.position(atDistance: min(sd + 8, spline.totalLength))
            let f = spline.tangent(atDistance: sd)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            for side in [-1, 1] as [Float] {
                var m = MeshBuilder()
                for k in 0..<3 {
                    let off = Float(k) * 0.17
                    Props.addOrientedTube(&m,
                        from: p0 + r * (half - 0.45 - off) * side + SIMD3(0, p0.y + ceilingHeight - 0.30, 0) - p0,
                        to: p1 + r * (half - 0.45 - off) * side + SIMD3(0, p1.y + ceilingHeight - 0.30, 0) - p0,
                        r0: 0.07, r1: 0.07, segments: 8)
                }
                let n = m.node(material: mats.pbr(.rustedMetal, tiling: 2.0,
                                                  seed: def.seed &+ 7, metalness: 0.85))
                n.simdPosition = p0
                services.addChildNode(n)
            }
            // A drooping cable across the corridor.
            if rng.chance(0.4) {
                let a = p0 + SIMD3(0, p0.y + ceilingHeight - 0.2, 0) - r * (half - 0.6)
                let b = p0 + SIMD3(0, p0.y + ceilingHeight - 0.2, 0) + r * (half - 0.6)
                services.addChildNode(Props.cableSpan(from: a - p0, to: b - p0, sag: rng.float(0.3, 0.8),
                                                      seed: def.seed &+ UInt64(sd)).with { $0.simdPosition = p0 })
            }
            sd += 8
        }
        root.addChildNode(EnvBuild.flatten(services, castsShadow: false))

        // ---- Equipment ---------------------------------------------------------
        let kit = SCNNode()
        EnvBuild.scatterAlongRail(spline: spline, step: 6, lateralRange: 2.8...4.1, corridor: 2.8,
                                  seed: def.seed &+ 17, density: quality.propDensity * 0.9) { pos, yaw, r, i in
            let y = ground(pos)
            let node: SCNNode
            switch r.int(0, 3) {
            case 0: node = Props.containmentTank(seed: def.seed &+ UInt64(i), occupied: r.chance(0.55))
            case 1: node = Props.locker(seed: def.seed &+ UInt64(i))
            case 2: node = Props.gurney(seed: def.seed &+ UInt64(i))
            default: node = Props.table(width: 1.5, depth: 0.7, height: 0.9, seed: def.seed &+ UInt64(i))
            }
            node.simdPosition = SIMD3(pos.x, y, pos.z)
            node.simdEulerAngles = SIMD3(0, yaw, 0)
            kit.addChildNode(node)
        }
        // Tanks glow, so they must not be flattened away into the static batch.
        root.addChildNode(kit)

        // ---- Lighting ----------------------------------------------------------
        var ld: Float = 4
        while ld < spline.totalLength {
            let p = spline.position(atDistance: ld)
            let f = spline.tangent(atDistance: ld)

            // Fluorescent tube in a housing.
            var m = MeshBuilder()
            m.addBox(center: SIMD3(0, ceilingHeight - 0.10, 0), size: SIMD3(0.24, 0.10, 2.2))
            let housing = m.node(material: mats.pbr(.metalPanel, tiling: 2, seed: def.seed, metalness: 0.7))
            housing.simdPosition = SIMD3(p.x, p.y, p.z)
            housing.simdEulerAngles = SIMD3(0, yawToward(f), 0)
            root.addChildNode(housing)

            let tube = SCNNode(geometry: SCNBox(width: 0.16, height: 0.04, length: 2.0, chamferRadius: 0.02))
            tube.geometry?.materials = [mats.glow(NSColor.Pal.fluorescent, intensity: 1.1)]
            tube.simdPosition = SIMD3(p.x, p.y + ceilingHeight - 0.17, p.z)
            tube.simdEulerAngles = SIMD3(0, yawToward(f), 0)
            tube.castsShadow = false
            root.addChildNode(tube)

            let failing = rng.chance(0.42)
            let l = EnvBuild.lamp(color: NSColor.Pal.fluorescent, intensity: 110, range: 14,
                                  castsShadow: quality.maxShadowCastingLights > 2, quality: quality)
            l.simdPosition = SIMD3(p.x, p.y + ceilingHeight - 0.28, p.z)
            l.addChildNode(tube)
            root.addChildNode(l)
            flickers.append(FlickerLight(node: l, baseIntensity: 110,
                                         speed: failing ? rng.float(5, 10) : rng.float(1, 2),
                                         depth: failing ? 0.9 : 0.06,
                                         isFailing: failing, seed: rng.float(0, 10)))
            ld += rng.float(7, 11)
        }

        // Red emergency strips near the floor: the only light that never fails.
        var ed: Float = 6
        while ed < spline.totalLength {
            let p = spline.position(atDistance: ed)
            let f = spline.tangent(atDistance: ed)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            for side in [-1, 1] as [Float] {
                let pos = p + r * ((half - 0.2) * side)
                let strip = SCNNode(geometry: SCNBox(width: 0.06, height: 0.06, length: 1.4, chamferRadius: 0))
                strip.geometry?.materials = [mats.glow(NSColor(rgb: 0.95, 0.12, 0.08), intensity: 2.4)]
                strip.simdPosition = SIMD3(pos.x, p.y + 0.22, pos.z)
                strip.simdEulerAngles = SIMD3(0, yawToward(f), 0)
                strip.castsShadow = false
                root.addChildNode(strip)
            }
            let l = EnvBuild.lamp(color: NSColor(rgb: 0.9, 0.15, 0.10), intensity: 70, range: 8,
                                  castsShadow: false, quality: quality)
            l.simdPosition = SIMD3(p.x, p.y + 0.3, p.z)
            root.addChildNode(l)
            ed += 12
        }

        let ambient = SCNNode()
        let amb = SCNLight()
        amb.type = .ambient
        amb.color = NSColor(rgb: 0.16, 0.22, 0.24)
        amb.intensity = 65
        ambient.light = amb
        root.addChildNode(ambient)

        // Steam venting from the pipe runs.
        if quality.particleBudget > 0.3 {
            var vd: Float = 9
            while vd < spline.totalLength {
                let p = spline.position(atDistance: vd)
                let ps = SCNParticleSystem()
                ps.birthRate = CGFloat(26 * quality.particleBudget)
                ps.particleLifeSpan = 2.2
                ps.particleLifeSpanVariation = 1.0
                ps.particleSize = 0.35
                ps.particleSizeVariation = 0.25
                ps.particleColor = NSColor(white: 0.85, alpha: 0.09)
                ps.particleImage = MaterialLibrary.softDot
                ps.blendMode = .alpha
                ps.particleVelocity = 1.1
                ps.particleVelocityVariation = 0.6
                ps.spreadingAngle = 32
                ps.acceleration = SCNVector3(0, 0.5, 0)
                ps.isLightingEnabled = false
                ps.sortingMode = .distance
                let n = SCNNode()
                n.addParticleSystem(ps)
                n.simdPosition = SIMD3(p.x, p.y + 0.25, p.z)
                n.castsShadow = false
                root.addChildNode(n)
                vd += rng.float(16, 26)
            }
        }

        return BuiltLevel(
            root: root,
            spline: spline,
            fogColor: NSColor(rgb: 0.022, 0.030, 0.032),
            fogStart: 9,
            fogEnd: min(quality.drawDistance, 48),
            fogDensityExponent: 1.5,
            background: NSColor(rgb: 0.010, 0.014, 0.016),
            flickerLights: flickers,
            ambience: .machinery,
            corridorHalfWidth: half - 0.5,
            groundHeight: ground,
            weaponLightColor: NSColor(rgb: 0.95, 0.97, 1.0),
            weaponLightIntensity: 430)
    }
}

private extension SCNNode {
    /// Small inline configuration helper, so a node can be positioned in an
    /// expression without a temporary variable.
    func with(_ body: (SCNNode) -> Void) -> SCNNode {
        body(self)
        return self
    }
}
