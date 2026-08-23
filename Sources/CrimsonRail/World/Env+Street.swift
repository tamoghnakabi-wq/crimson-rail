import Foundation
import SceneKit
import AppKit
import simd

extension Environments {

    /// Level 3 — Vessel Row.
    ///
    /// The only level lit predominantly from below: burning wrecks and fire
    /// barrels throw orange up onto everything, with sodium streetlights as the
    /// cool-by-comparison counterpoint. Rain ties the whole frame together.
    static func buildStreet(_ def: LevelDef, spline: Spline, quality: GraphicsSettings) -> BuiltLevel {
        let root = SCNNode()
        root.name = "level"
        var rng = Rand(seed: def.seed)
        var flickers: [FlickerLight] = []
        let mats = MaterialLibrary.shared
        let ground = EnvBuild.railHeightField(spline: spline)
        let centre = spline.position(atDistance: spline.totalLength * 0.5)

        let roadHalf: Float = 7.0

        // ---- Road surface and pavements --------------------------------------
        let base = Props.ground(size: 240, kind: .asphalt, tiling: 0.28, heightScale: 0,
                                divisions: 4, seed: def.seed)
        base.simdPosition = SIMD3(centre.x, -0.02, centre.z)
        root.addChildNode(base)
        root.addChildNode(EnvBuild.pathRibbon(spline: spline, width: roadHalf * 2,
                                              kind: .cobblestone, tiling: 0.45, seed: def.seed, yOffset: 0.01))

        // Kerbs and pavement strips either side.
        let kerbs = SCNNode()
        var d: Float = 0
        while d < spline.totalLength {
            let p = spline.position(atDistance: d)
            let f = spline.tangent(atDistance: d)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            for side in [-1, 1] as [Float] {
                var m = MeshBuilder()
                m.addBox(center: .zero, size: SIMD3(3.0, 0.17, 4.2), uvScale: 1)
                let n = m.node(material: mats.pbr(.concrete, tiling: 0.6, seed: def.seed &+ 4))
                let pos = p + r * ((roadHalf + 1.4) * side)
                n.simdPosition = SIMD3(pos.x, 0.08, pos.z)
                n.simdEulerAngles = SIMD3(0, yawToward(f), 0)
                kerbs.addChildNode(n)
            }
            d += 4
        }
        root.addChildNode(EnvBuild.flatten(kerbs, castsShadow: false))

        // ---- Building frontage both sides -------------------------------------
        let blocks = SCNNode()
        var bd: Float = -4
        while bd < spline.totalLength + 8 {
            let clamped = clamp(bd, 0, spline.totalLength)
            let p = spline.position(atDistance: clamped)
            let f = spline.tangent(atDistance: clamped)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let width = rng.float(9, 15)
            for side in [-1, 1] as [Float] {
                let facade = Props.facade(width: width, height: rng.float(9, 17),
                                          seed: def.seed &+ UInt64(bd + 100), lit: rng.chance(0.7))
                let pos = p + r * ((roadHalf + 3.2) * side)
                facade.simdPosition = SIMD3(pos.x, 0, pos.z)
                facade.simdEulerAngles = SIMD3(0, yawToward(f) + (side > 0 ? -.pi / 2 : .pi / 2), 0)
                blocks.addChildNode(facade)
            }
            bd += width
        }
        root.addChildNode(EnvBuild.flatten(blocks))

        // ---- Wrecks, skips, barricades ----------------------------------------
        let debris = SCNNode()
        // Debris sits well out from the centre line: these props are up to 4.5 m
        // long and freely rotated, so anchoring them at the corridor edge is what
        // keeps a walkable lane down the middle.
        EnvBuild.scatterAlongRail(spline: spline, step: 9, lateralRange: 5.2...6.6, corridor: 5.2,
                                  seed: def.seed &+ 21, density: quality.propDensity * 0.9) { pos, yaw, r, i in
            let burnt = r.chance(0.35)
            let node: SCNNode
            switch r.int(0, 3) {
            case 0, 1: node = Props.wreckedCar(seed: def.seed &+ UInt64(i), burnt: burnt)
            case 2: node = Props.dumpster(seed: def.seed &+ UInt64(i))
            default: node = Props.barricade(width: r.float(2.4, 4.0), seed: def.seed &+ UInt64(i))
            }
            node.simdPosition = SIMD3(pos.x, 0, pos.z)
            debris.addChildNode(node)
            _ = yaw
        }
        root.addChildNode(EnvBuild.flatten(debris))

        root.addChildNode(EnvBuild.flatten(
            rubbleField(spline: spline, quality: quality, seed: def.seed &+ 31), castsShadow: false))

        // ---- Streetlights ------------------------------------------------------
        var ld: Float = 10
        while ld < spline.totalLength {
            let p = spline.position(atDistance: ld)
            let f = spline.tangent(atDistance: ld)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let side: Float = rng.chance(0.5) ? -1 : 1
            let working = rng.chance(0.6)
            let lamp = Props.streetlight(seed: def.seed &+ UInt64(ld), working: working)
            let pos = p + r * ((roadHalf + 0.9) * side)
            lamp.simdPosition = SIMD3(pos.x, 0, pos.z)
            lamp.simdEulerAngles = SIMD3(0, yawToward(f) + (side > 0 ? -.pi / 2 : .pi / 2), 0)
            root.addChildNode(lamp)

            if working {
                let l = EnvBuild.lamp(color: NSColor.Pal.sodium, intensity: 520, range: 24,
                                      castsShadow: quality.maxShadowCastingLights > 2, quality: quality)
                l.simdPosition = SIMD3(pos.x, 5.6, pos.z)
                root.addChildNode(l)
                // A failing sodium lamp buzzes and drops out; a good one is steady.
                if rng.chance(0.35) {
                    flickers.append(FlickerLight(node: l, baseIntensity: 520, speed: rng.float(6, 11),
                                                 depth: 0.5, isFailing: true, seed: rng.float(0, 10)))
                }
            }
            ld += rng.float(16, 24)
        }

        // ---- Fires: the level's real light source -------------------------------
        var fd: Float = 14
        while fd < spline.totalLength {
            let p = spline.position(atDistance: fd)
            let f = spline.tangent(atDistance: fd)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let side: Float = rng.chance(0.5) ? -1 : 1
            let pos = p + r * (rng.float(4.2, 6.2) * side)

            let barrel = SCNNode()
            var m = MeshBuilder()
            m.addPrism(center: .zero, radii: Array(repeating: 0.34, count: 12), height: 0.88,
                       uvScale: 2, capTop: false)
            barrel.addChildNode(m.node(material: mats.pbr(.rustedMetal, tiling: 2.5,
                                                          seed: def.seed &+ UInt64(fd), metalness: 0.7)))
            barrel.simdPosition = SIMD3(pos.x, 0, pos.z)
            root.addChildNode(barrel)

            root.addChildNode(fireEmitter(at: SIMD3(pos.x, 0.85, pos.z), scale: 1.0, quality: quality))

            let l = EnvBuild.lamp(color: NSColor.Pal.fire, intensity: 300, range: 19,
                                  castsShadow: quality.maxShadowCastingLights > 1, quality: quality)
            l.simdPosition = SIMD3(pos.x, 1.25, pos.z)
            root.addChildNode(l)
            flickers.append(FlickerLight(node: l, baseIntensity: 300, speed: rng.float(7, 13),
                                         depth: 0.42, isFailing: false, seed: rng.float(0, 10)))
            fd += rng.float(17, 27)
        }

        // ---- The barricade at the end -------------------------------------------
        do {
            let end = spline.totalLength
            let p = spline.position(atDistance: end)
            let f = spline.tangent(atDistance: end)
            let wall = Props.barricade(width: 13, seed: def.seed &+ 900)
            wall.simdPosition = SIMD3(p.x, 0, p.z)
            wall.simdEulerAngles = SIMD3(0, yawToward(f) + .pi / 2, 0)
            root.addChildNode(wall)
            let l = EnvBuild.lamp(color: NSColor(rgb: 0.55, 0.85, 1.0), intensity: 900, range: 20,
                                  castsShadow: false, quality: quality)
            l.simdPosition = SIMD3(p.x, 3.2, p.z)
            root.addChildNode(l)
        }

        // ---- Key light and sky ----------------------------------------------
        let key = SCNNode()
        let kl = SCNLight()
        kl.type = .directional
        // Sky bounce from a burning city: dim, warm, and from above.
        kl.color = NSColor(rgb: 0.85, 0.52, 0.32)
        kl.intensity = 760
        let dir = simd_normalize(SIMD3<Float>(0.62, -0.58, 0.53))
        EnvBuild.configureKeyShadow(kl, quality: quality, range: 30)
        kl.shadowColor = NSColor(white: 0, alpha: 0.55)
        key.light = kl
        key.simdOrientation = lookRotation(forward: dir)
        root.addChildNode(key)

        let ambient = SCNNode()
        let amb = SCNLight()
        amb.type = .ambient
        amb.color = NSColor(rgb: 0.30, 0.20, 0.16)
        amb.intensity = 210
        ambient.light = amb
        root.addChildNode(ambient)

        // ---- Rain ---------------------------------------------------------------
        if quality.particleBudget > 0.3 {
            root.addChildNode(rainVolume(spline: spline, quality: quality))
        }
        root.addChildNode(groundMist(spline: spline, quality: quality, seed: def.seed,
                                     color: NSColor(rgb: 0.65, 0.50, 0.40), height: 0.4))

        return BuiltLevel(
            root: root,
            spline: spline,
            fogColor: NSColor(rgb: 0.062, 0.040, 0.031),
            fogStart: 12,
            fogEnd: min(quality.drawDistance, 72),
            fogDensityExponent: 1.6,
            background: NSColor(rgb: 0.035, 0.022, 0.018),
            flickerLights: flickers,
            ambience: .fire,
            corridorHalfWidth: roadHalf - 0.7,
            groundHeight: ground,
            keyLightNode: key,
            keyLightDirection: dir,
            keyLightRange: 30,
            weaponLightColor: NSColor(rgb: 1.0, 0.94, 0.86),
            weaponLightIntensity: 560)
    }

    // MARK: Shared street pieces

    static func rubbleField(spline: Spline, quality: GraphicsSettings, seed: UInt64) -> SCNNode {
        let group = SCNNode()
        EnvBuild.scatterAlongRail(spline: spline, step: 6, lateralRange: 2.5...9.0, corridor: 2.5,
                                  seed: seed, density: quality.propDensity * 0.7) { pos, _, r, _ in
            let n = Props.rubble(radius: r.float(0.8, 2.0), count: r.int(6, 16),
                                 seed: UInt64(r.int(1, 9999)), kind: .gravel)
            n.simdPosition = SIMD3(pos.x, 0.01, pos.z)
            group.addChildNode(n)
        }
        return group
    }

    /// Flame plus embers for a barrel or a burning wreck.
    static func fireEmitter(at position: SIMD3<Float>, scale: Float, quality: GraphicsSettings) -> SCNNode {
        let node = SCNNode()
        node.simdPosition = position
        guard quality.particleBudget > 0.1 else { return node }

        let flame = SCNParticleSystem()
        flame.birthRate = CGFloat(70 * quality.particleBudget)
        flame.particleLifeSpan = 0.55
        flame.particleLifeSpanVariation = 0.3
        flame.particleSize = CGFloat(0.34 * scale)
        flame.particleSizeVariation = 0.2
        flame.particleColor = NSColor(rgb: 1.0, 0.55, 0.15, 0.85)
        flame.particleColorVariation = SCNVector4(0.05, 0.15, 0.05, 0.1)
        flame.particleImage = MaterialLibrary.softDot
        flame.blendMode = .additive
        flame.emitterShape = SCNSphere(radius: CGFloat(0.22 * scale))
        flame.birthLocation = .volume
        flame.particleVelocity = CGFloat(1.5 * scale)
        flame.particleVelocityVariation = 0.7
        flame.spreadingAngle = 22
        flame.acceleration = SCNVector3(0, 2.4, 0)
        flame.isLightingEnabled = false
        flame.sortingMode = .none
        // Shrink as it rises, which is what makes a column of sprites read as fire.
        flame.propertyControllers = [.size: sizeRamp(from: 0.34 * scale, to: 0.02)]
        node.addParticleSystem(flame)

        let embers = SCNParticleSystem()
        embers.birthRate = CGFloat(9 * quality.particleBudget)
        embers.particleLifeSpan = 2.4
        embers.particleLifeSpanVariation = 1.4
        embers.particleSize = 0.035
        embers.particleColor = NSColor(rgb: 1.0, 0.62, 0.22, 0.9)
        embers.particleImage = MaterialLibrary.softDot
        embers.blendMode = .additive
        embers.emitterShape = SCNSphere(radius: 0.25)
        embers.birthLocation = .volume
        embers.particleVelocity = 1.6
        embers.particleVelocityVariation = 1.2
        embers.spreadingAngle = 40
        embers.acceleration = SCNVector3(0.4, 1.2, 0.2)
        embers.isLightingEnabled = false
        node.addParticleSystem(embers)
        return node
    }

    private static func sizeRamp(from: Float, to: Float) -> SCNParticlePropertyController {
        let anim = CABasicAnimation(keyPath: "size")
        anim.fromValue = from
        anim.toValue = to
        return SCNParticlePropertyController(animation: anim)
    }

    /// Rain as a few large emitters that travel with the camera would be ideal;
    /// a static chain along the rail is simpler and reads the same at these speeds.
    static func rainVolume(spline: Spline, quality: GraphicsSettings) -> SCNNode {
        let group = SCNNode()
        var d: Float = 0
        while d < spline.totalLength {
            let p = spline.position(atDistance: d)
            let ps = SCNParticleSystem()
            ps.birthRate = CGFloat(220 * quality.particleBudget)
            ps.particleLifeSpan = 1.3
            ps.particleSize = 0.012
            ps.particleSizeVariation = 0.006
            ps.particleColor = NSColor(rgb: 0.62, 0.70, 0.80, 0.42)
            ps.particleImage = MaterialLibrary.softDot
            ps.blendMode = .alpha
            ps.emitterShape = SCNBox(width: 30, height: 0.2, length: 30, chamferRadius: 0)
            ps.birthLocation = .volume
            ps.particleVelocity = 13
            ps.particleVelocityVariation = 3
            ps.spreadingAngle = 4
            ps.acceleration = SCNVector3(0.8, -9, 0)
            ps.isLightingEnabled = false
            ps.sortingMode = .none
            ps.orientationMode = .billboardScreenAligned
            // Stretch each drop into a streak.
            ps.particleSizeVariation = 0.01
            let n = SCNNode()
            n.addParticleSystem(ps)
            n.simdPosition = SIMD3(p.x, 14, p.z)
            n.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
            n.castsShadow = false
            group.addChildNode(n)
            d += 26
        }
        return group
    }
}
