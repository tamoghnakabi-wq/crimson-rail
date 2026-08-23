import Foundation
import SceneKit
import AppKit
import simd

/// Every transient visual: muzzle flashes, blood, impact debris, gibs, decals.
///
/// Everything is pooled or budgeted. A rail shooter generates hundreds of these
/// per encounter, and unbounded `SCNNode` churn is the fastest way to turn a
/// smooth 120 fps into a stutter halfway through level three.
final class Effects {
    private unowned let scene: SCNScene
    private let root: SCNNode
    private var quality: GraphicsSettings
    private var gore: Float

    /// Decals and corpses are ring buffers: oldest is recycled once full.
    private var decals: [SCNNode] = []
    private var gibs: [(node: SCNNode, velocity: SIMD3<Float>, spin: SIMD3<Float>, age: Float)] = []
    private var corpses: [SCNNode] = []
    private var lights: [(node: SCNNode, life: Float, maxLife: Float, base: Float)] = []
    private var rng = Rand(seed: 0xB100D)

    /// Reused flash card, so firing does not allocate.
    private let muzzleCard: SCNNode
    private let muzzleLight: SCNNode
    private var muzzleTimer: Float = 0

    init(scene: SCNScene, root: SCNNode, quality: GraphicsSettings, gore: Float) {
        self.scene = scene
        self.root = root
        self.quality = quality
        self.gore = gore

        let plane = SCNPlane(width: 0.85, height: 0.85)
        plane.materials = [MaterialLibrary.shared.additive(NSColor(rgb: 1.0, 0.86, 0.55),
                                                           image: MaterialLibrary.flashStar)]
        muzzleCard = SCNNode(geometry: plane)
        muzzleCard.castsShadow = false
        muzzleCard.opacity = 0
        muzzleCard.renderingOrder = 100

        let l = SCNLight()
        l.type = .omni
        l.color = NSColor(rgb: 1.0, 0.82, 0.55)
        l.intensity = 0
        l.attenuationStartDistance = 0.5
        l.attenuationEndDistance = 22
        l.castsShadow = false
        muzzleLight = SCNNode()
        muzzleLight.light = l
    }

    /// Attaches the muzzle rig under the camera so the flash tracks the aim.
    func attachMuzzle(to cameraNode: SCNNode) {
        muzzleCard.simdPosition = SIMD3(0.20, -0.16, -0.62)
        cameraNode.addChildNode(muzzleCard)
        muzzleLight.simdPosition = SIMD3(0.20, -0.16, -0.7)
        cameraNode.addChildNode(muzzleLight)
    }

    // MARK: Frame

    func update(dt: Float) {
        // Muzzle flash: a very short, hard decay. Anything slower reads as a flare.
        if muzzleTimer > 0 {
            muzzleTimer = max(0, muzzleTimer - dt)
            let t = muzzleTimer / 0.055
            muzzleCard.opacity = CGFloat(t * t)
            muzzleLight.light?.intensity = CGFloat(t * 5200)
        } else {
            muzzleCard.opacity = 0
            muzzleLight.light?.intensity = 0
        }

        // Gibs: simple ballistic arcs, no physics engine needed.
        var i = 0
        while i < gibs.count {
            gibs[i].age += dt
            gibs[i].velocity.y -= 11.0 * dt
            gibs[i].node.simdPosition += gibs[i].velocity * dt
            let spin = gibs[i].spin * dt
            gibs[i].node.simdOrientation = simd_quatf(angle: simd_length(spin),
                                                      axis: simd_length(spin) > 1e-6 ? simd_normalize(spin) : SIMD3(0, 1, 0))
                * gibs[i].node.simdOrientation
            if gibs[i].age > 3.2 || gibs[i].node.simdPosition.y < -1.5 {
                gibs[i].node.removeFromParentNode()
                gibs.remove(at: i)
            } else {
                if gibs[i].age > 2.4 { gibs[i].node.opacity = CGFloat(1 - (gibs[i].age - 2.4) / 0.8) }
                i += 1
            }
        }

        // Transient point lights (impacts, spits, explosions).
        var j = 0
        while j < lights.count {
            lights[j].life -= dt
            if lights[j].life <= 0 {
                lights[j].node.removeFromParentNode()
                lights.remove(at: j)
            } else {
                let t = lights[j].life / lights[j].maxLife
                lights[j].node.light?.intensity = CGFloat(lights[j].base * t * t)
                j += 1
            }
        }
    }

    // MARK: Weapon

    func muzzleFlash() {
        muzzleTimer = 0.055
        muzzleCard.simdEulerAngles = SIMD3(0, 0, rng.float(0, 2 * .pi))
        let s = rng.float(0.85, 1.25)
        muzzleCard.simdScale = SIMD3(s, s, 1)
    }

    /// Sparks and dust where a bullet hits the world.
    func worldImpact(at point: SIMD3<Float>, normal: SIMD3<Float>) {
        guard quality.particleBudget > 0.05 else { return }
        let ps = SCNParticleSystem()
        ps.birthRate = 0
        ps.particleLifeSpan = 0.42
        ps.particleLifeSpanVariation = 0.25
        ps.particleSize = 0.022
        ps.particleSizeVariation = 0.02
        ps.particleColor = NSColor(rgb: 0.75, 0.68, 0.58)
        ps.particleImage = MaterialLibrary.softDot
        ps.blendMode = .alpha
        ps.emissionDuration = CGFloat(0.02)
        ps.birthLocation = .vertex
        ps.particleVelocity = 3.2
        ps.particleVelocityVariation = 2.4
        ps.spreadingAngle = 62
        ps.isAffectedByGravity = true
        ps.acceleration = SCNVector3(0, -7, 0)
        ps.isLightingEnabled = false
        ps.dampingFactor = 1.2
        emitBurst(ps, count: Int(11 * quality.particleBudget), at: point, direction: normal)
    }

    /// Blood spray. `force` scales the size of the burst (a headshot is bigger).
    func bloodBurst(at point: SIMD3<Float>, direction: SIMD3<Float>, force: Float) {
        guard gore > 0.01, quality.particleBudget > 0.05 else { return }
        let ps = SCNParticleSystem()
        ps.birthRate = 0
        ps.particleLifeSpan = 0.7
        ps.particleLifeSpanVariation = 0.5
        ps.particleSize = CGFloat(0.038 * force)
        ps.particleSizeVariation = 0.03
        ps.particleColor = NSColor(rgb: 0.42, 0.02, 0.02)
        ps.particleColorVariation = SCNVector4(0.06, 0.01, 0.01, 0)
        ps.particleImage = MaterialLibrary.gooDot
        ps.blendMode = .alpha
        ps.emissionDuration = CGFloat(0.03)
        ps.birthLocation = .vertex
        ps.particleVelocity = CGFloat(3.4 * force)
        ps.particleVelocityVariation = 2.8
        ps.spreadingAngle = 48
        ps.isAffectedByGravity = true
        ps.acceleration = SCNVector3(0, -9.5, 0)
        ps.isLightingEnabled = false
        ps.particleAngularVelocity = 4
        ps.particleAngularVelocityVariation = 8
        emitBurst(ps, count: Int(Float(18) * force * gore * quality.particleBudget),
                  at: point, direction: direction)
    }

    /// A brief mist for headshots — sells the pop without needing more particles.
    func headshotSpray(at point: SIMD3<Float>, direction: SIMD3<Float>) {
        guard gore > 0.01 else { return }
        bloodBurst(at: point, direction: direction, force: 2.1)
        let mist = SCNParticleSystem()
        mist.birthRate = 0
        mist.particleLifeSpan = 1.1
        mist.particleSize = 0.20
        mist.particleSizeVariation = 0.14
        mist.particleColor = NSColor(rgb: 0.30, 0.02, 0.02, 0.5)
        mist.particleImage = MaterialLibrary.softDot
        mist.blendMode = .alpha
        mist.emissionDuration = 0.05
        mist.birthLocation = .vertex
        mist.particleVelocity = 1.1
        mist.particleVelocityVariation = 0.9
        mist.spreadingAngle = 80
        mist.isLightingEnabled = false
        emitBurst(mist, count: Int(9 * gore * quality.particleBudget), at: point, direction: direction)
    }

    /// Sprays a splat onto the ground beneath a kill.
    func bloodDecal(at point: SIMD3<Float>, groundY: Float) {
        guard gore > 0.01, quality.decalBudget > 0 else { return }
        let size = CGFloat(rng.float(0.7, 1.5))
        let plane = SCNPlane(width: size, height: size)
        plane.materials = [MaterialLibrary.shared.bloodDecal(seed: UInt64(rng.int(0, 7)))]
        let n = SCNNode(geometry: plane)
        // Lie flat, just above the surface so it does not z-fight the ground.
        n.simdEulerAngles = SIMD3(-.pi / 2, rng.float(0, 2 * .pi), 0)
        n.simdPosition = SIMD3(point.x, groundY + 0.015, point.z)
        n.castsShadow = false
        n.renderingOrder = 5
        root.addChildNode(n)
        decals.append(n)
        while decals.count > quality.decalBudget {
            decals.removeFirst().removeFromParentNode()
        }
    }

    /// Turns a severed limb into a tumbling piece of debris.
    func launchGib(_ node: SCNNode, from origin: SIMD3<Float>, direction: SIMD3<Float>) {
        guard gore > 0.01 else { node.removeFromParentNode(); return }
        root.addChildNode(node)
        node.castsShadow = false
        let v = direction.normalizedSafe * rng.float(2.2, 4.5) + SIMD3(0, rng.float(1.6, 3.4), 0)
        let spin = SIMD3<Float>(rng.float(-9, 9), rng.float(-9, 9), rng.float(-9, 9))
        gibs.append((node, v, spin, 0))
        while gibs.count > 24 {
            gibs.removeFirst().node.removeFromParentNode()
        }
        bloodBurst(at: origin, direction: direction, force: 1.4)
    }

    /// Registers a corpse so old ones can be retired when the budget is exceeded.
    func registerCorpse(_ node: SCNNode) {
        corpses.append(node)
        while corpses.count > quality.maxCorpses {
            let old = corpses.removeFirst()
            // Sink and fade rather than vanish — a corpse blinking out is jarring.
            old.runAction(.sequence([
                .group([.fadeOut(duration: 1.1), .moveBy(x: 0, y: -0.55, z: 0, duration: 1.1)]),
                .removeFromParentNode()
            ]))
        }
    }

    func clearCorpses() {
        for c in corpses { c.removeFromParentNode() }
        corpses.removeAll()
    }

    // MARK: Lights

    /// Short-lived point light used by impacts and acid bursts.
    func flashLight(at point: SIMD3<Float>, color: NSColor, intensity: Float, life: Float) {
        guard quality.preset != .low else { return }
        let l = SCNLight()
        l.type = .omni
        l.color = color
        l.intensity = CGFloat(intensity)
        l.attenuationStartDistance = 0.2
        l.attenuationEndDistance = 12
        l.castsShadow = false
        let n = SCNNode()
        n.light = l
        n.simdPosition = point
        root.addChildNode(n)
        lights.append((n, life, life, intensity))
        while lights.count > 8 {
            lights.removeFirst().node.removeFromParentNode()
        }
    }

    // MARK: Helpers

    /// One-shot particle burst. SceneKit has no "emit N now" call, so a system
    /// with `birthRate = 0` is triggered by hand and the node self-removes.
    private func emitBurst(_ ps: SCNParticleSystem, count: Int,
                           at point: SIMD3<Float>, direction: SIMD3<Float>) {
        guard count > 0 else { return }
        ps.birthRate = CGFloat(count) / max(ps.emissionDuration, 0.01)
        ps.loops = false
        ps.sortingMode = .none
        ps.orientationMode = .billboardScreenAligned
        let n = SCNNode()
        n.simdPosition = point
        n.simdOrientation = lookRotation(forward: direction.normalizedSafe)
        // The emitter's own +Y is the spray axis, so point it down the normal.
        n.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction.normalizedSafe)
        n.addParticleSystem(ps)
        root.addChildNode(n)
        let life = Float(ps.particleLifeSpan + ps.particleLifeSpanVariation) + Float(ps.emissionDuration)
        n.runAction(.sequence([.wait(duration: Double(life) + 0.2), .removeFromParentNode()]))
    }

    func setQuality(_ q: GraphicsSettings, gore: Float) {
        quality = q
        self.gore = gore
    }
}
