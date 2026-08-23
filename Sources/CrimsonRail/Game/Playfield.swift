import Foundation
import SceneKit
import AppKit
import simd

/// One playable level instance: the scene, the camera on its rail, and (added by
/// the combat and director layers) everything living in it.
final class Playfield {
    let def: LevelDef
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let player: PlayerController
    /// Projection of world position onto the level's authored spine. Encounters,
    /// spawns and the progress bar are all still written in rail coordinates.
    let projector: RailProjector
    let built: BuiltLevel
    let sky: SkyDome
    var quality: GraphicsSettings
    var gameplay: GameplaySettings

    /// Parent for everything spawned at runtime, so a restart can wipe it in one go.
    let dynamicRoot = SCNNode()
    /// Weapon-mounted light. Diegetic, and the reason enemies stay readable in a
    /// level this dark without flattening the lighting.
    private let weaponLight = SCNNode()
    private var weaponLightBase: Float = 900

    private var elapsed: Float = 0

    /// Every local light in the level, with its authored intensity. Only the
    /// nearest handful are left enabled each frame.
    private var localLights: [(node: SCNNode, intensity: CGFloat)] = []
    private var lightCullTimer: Float = 0
    /// Lights currently within the budget. Flicker only modulates these.
    private var activeLights: Set<ObjectIdentifier> = []

    init(def: LevelDef, quality: GraphicsSettings, gameplay: GameplaySettings) {
        self.def = def
        self.quality = quality
        self.gameplay = gameplay

        var q = quality
        if DebugFlags.noShadows { q.shadowsEnabled = false; q.maxShadowCastingLights = 0 }
        if DebugFlags.noAO { q.ambientOcclusion = false }
        if DebugFlags.noBloom { q.bloom = false }
        if DebugFlags.noParticles { q.particleBudget = 0 }
        self.quality = q
        MaterialLibrary.shared.configure(quality: q)
        built = Environments.build(def, quality: q)
        projector = RailProjector(spline: built.spline)
        player = PlayerController(projector: projector,
                                  collision: CollisionWorld(root: built.root),
                                  groundAt: built.groundHeight,
                                  corridorHalfWidth: built.corridorHalfWidth)
        player.swayAmount = gameplay.cameraSway
        player.shakeAmount = gameplay.screenShake
        player.lookSensitivity = gameplay.lookSensitivity

        sky = SkyDome(style: Playfield.skyStyle(for: def.environment), seed: def.seed)

        scene.rootNode.addChildNode(built.root)
        scene.rootNode.addChildNode(dynamicRoot)
        if !DebugFlags.noSky { scene.rootNode.addChildNode(sky.node) }
        if DebugFlags.lightScale != 1 {
            let s = DebugFlags.lightScale
            built.root.enumerateHierarchy { node, _ in
                if let l = node.light { l.intensity *= CGFloat(s) }
            }
        }

        configureCamera()
        configureAtmosphere()
        collectLocalLights()
        scene.rootNode.addChildNode(cameraNode)
    }

    private static func skyStyle(for env: EnvironmentKind) -> SkyDome.Style {
        switch env {
        case .cemetery: return .moonlitNight
        case .manor: return .blackVault
        case .street: return .burningOvercast
        case .lab: return .blackVault
        case .spire: return .storm
        }
    }

    // MARK: Setup

    private func configureCamera() {
        let cam = SCNCamera()
        // Set the projection axis explicitly. SceneKit's default has changed
        // across releases, and reading a horizontal FOV as vertical (or the
        // reverse) silently produces either a fisheye or a keyhole.
        cam.projectionDirection = .vertical
        cam.fieldOfView = 55
        // Keep the near/far ratio modest: depth-based effects (SSAO especially)
        // band badly once it climbs past a few thousand.
        cam.zNear = 0.14
        cam.zFar = Double(max(built.fogEnd * 1.6, 140))

        cam.wantsHDR = quality.hdr
        if quality.hdr {
            cam.exposureOffset = 0.55
            cam.averageGray = 0.18
            cam.whitePoint = 1.0
            // Auto-exposure is wrong for this game: every muzzle flash is a huge
            // luminance spike, so adaptation pumps the whole scene darker on each
            // shot and then drifts back. Fixed exposure keeps the art direction.
            cam.wantsExposureAdaptation = false
        }
        if quality.bloom {
            cam.bloomThreshold = 0.88
            cam.bloomIntensity = 0.55
            cam.bloomBlurRadius = 14
            cam.bloomIterationCount = quality.preset == .ultra ? 3 : 2
        }
        if quality.ambientOcclusion {
            cam.screenSpaceAmbientOcclusionIntensity = 1.1
            cam.screenSpaceAmbientOcclusionRadius = 1.1
            cam.screenSpaceAmbientOcclusionBias = 0.04
            cam.screenSpaceAmbientOcclusionDepthThreshold = 0.35
        }
        if quality.vignette {
            cam.vignettingIntensity = 0.55
            cam.vignettingPower = 1.5
        }
        if quality.colorFringe {
            cam.colorFringeIntensity = 0.35
            cam.colorFringeStrength = 0.6
        }
        if quality.filmGrain {
            cam.grainIntensity = 0.16
            cam.grainScale = 1.4
            cam.grainIsColored = false
        }
        cam.motionBlurIntensity = quality.motionBlur ? 0.55 : 0
        cam.contrast = 0.10
        cam.saturation = 0.92

        cameraNode.camera = cam
        cameraNode.name = "camera"

        // Weapon light: a tight warm cone that travels with the aim. Without it a
        // level this dark either hides the enemies or has to be lit so evenly it
        // stops being frightening.
        let light = SCNLight()
        light.type = .spot
        light.color = built.weaponLightColor
        light.intensity = CGFloat(built.weaponLightIntensity)
        weaponLightBase = built.weaponLightIntensity
        light.spotInnerAngle = 22
        light.spotOuterAngle = 58
        light.attenuationStartDistance = 1.5
        light.attenuationEndDistance = 24
        // Deliberately casts no shadow. It sits at the eye, so it is nearly
        // shadow-free by construction — but it rakes the floor at a grazing
        // angle, which is the worst case for shadow-map acne: measured, it more
        // than halved ground brightness while adding nothing visible. Skipping
        // it also saves a full shadow-map render every frame.
        light.castsShadow = false
        weaponLight.light = light
        // Offset down-right so the cone reads as coming from a held weapon rather
        // than from the middle of the player's forehead.
        weaponLight.simdPosition = SIMD3(0.22, -0.18, 0)
        if !DebugFlags.noWeaponLight { cameraNode.addChildNode(weaponLight) }
    }

    private func configureAtmosphere() {
        scene.background.contents = built.background
        scene.fogColor = built.fogColor
        scene.fogStartDistance = CGFloat(DebugFlags.noFog ? 10_000 : built.fogStart)
        scene.fogEndDistance = CGFloat(DebugFlags.noFog ? 20_000 : built.fogEnd)
        scene.fogDensityExponent = CGFloat(built.fogDensityExponent)
    }

    // MARK: Frame

    func update(dt: Float, input: PlayerController.MoveInput = .init()) {
        elapsed += dt
        player.update(dt: dt, input: input, cameraNode: cameraNode)
        sky.update(cameraPosition: cameraNode.simdPosition)
        anchorKeyLight()
        lightCullTimer -= dt
        if lightCullTimer <= 0 {
            lightCullTimer = 0.2
            cullLocalLights()
        }
        updateFlickers()
    }

    /// Indexes the level's point and spot lights so they can be culled by distance.
    private func collectLocalLights() {
        built.root.enumerateHierarchy { node, _ in
            guard let l = node.light, l.type == .omni || l.type == .spot else { return }
            localLights.append((node, l.intensity))
        }
    }

    /// Enables only the nearest lights.
    ///
    /// SceneKit evaluates every enabled light per fragment in its forward path,
    /// so a corridor with twenty-odd fluorescents costs twenty-odd light
    /// evaluations everywhere — measured at 14.3 ms/frame on level 4 before this,
    /// against 4.8 ms for a level with the same geometry and fewer lamps. Only a
    /// handful are ever close enough to contribute anything visible.
    private func cullLocalLights() {
        guard !localLights.isEmpty else { return }
        let budget: Int
        switch quality.preset {
        case .low: budget = 4
        case .medium: budget = 6
        case .high: budget = 9
        case .ultra: budget = 14
        }
        let eye = cameraNode.simdPosition
        // Sorting every frame is wasteful and the answer barely changes; a few
        // times a second is indistinguishable and effectively free.
        var ranked = localLights.map { (entry: $0, d: simd_distance_squared($0.node.simdWorldPosition, eye)) }
        ranked.sort { $0.d < $1.d }
        activeLights.removeAll(keepingCapacity: true)
        for (i, r) in ranked.enumerated() {
            let keep = i < budget
            // `isHidden` genuinely removes the light from SceneKit's per-fragment
            // loop. Setting intensity to zero does not: the light is still
            // evaluated, so the cost stays and only the contribution goes away.
            r.entry.node.isHidden = !keep
            if keep {
                activeLights.insert(ObjectIdentifier(r.entry.node))
                r.entry.node.light?.intensity = r.entry.intensity
            }
        }
    }

    /// Keeps the key light's shadow frustum centred on what the player can see.
    /// A directional light parked at a fixed world position only covers a slab of
    /// the level; the rest renders as if permanently in shadow.
    private func anchorKeyLight() {
        guard let key = built.keyLightNode else { return }
        // Bias the centre ahead of the camera — the player is looking forward, so
        // that is where shadow resolution is worth spending.
        let focus = cameraNode.simdPosition + cameraForward * (built.keyLightRange * 0.35)
        key.simdPosition = focus - built.keyLightDirection * (built.keyLightRange * 1.4)
    }

    /// Candles waver; failing fluorescents drop out entirely and snap back. Both
    /// are driven from noise rather than a sine so they never look metronomic.
    private func updateFlickers() {
        for f in built.flickerLights {
            guard let light = f.node.light else { continue }
            // A culled light stays off; re-lighting it here would undo the cull.
            if !localLights.isEmpty, f.node.light?.type != .directional,
               !activeLights.contains(ObjectIdentifier(f.node)) { continue }
            let t = elapsed * f.speed + f.seed
            var v: Float
            if f.isFailing {
                let n = Noise.fbm(t * 0.5, f.seed, octaves: 3, period: 8, seed: 17)
                // Mostly on, with hard dropouts.
                v = n < 0.36 ? (n < 0.28 ? 0.04 : 0.45) : 1.0
                if Noise.value(t * 6, f.seed, period: 16, seed: 23) > 0.86 { v *= 0.25 }
            } else {
                let n = Noise.fbm(t, f.seed, octaves: 3, period: 8, seed: 31)
                v = 1 - (n - 0.5) * 2 * f.depth
            }
            light.intensity = CGFloat(f.baseIntensity * clamp(v, 0.02, 1.35))
            // Keep the visible bulb in step with its light. The bulb is a
            // sibling of the light node, so search the shared parent.
            let siblings = f.node.parent?.childNodes ?? f.node.childNodes
            for child in siblings where child.geometry != nil {
                child.geometry?.firstMaterial?.emission.intensity = CGFloat(clamp(v, 0.02, 1.35) * 2.5)
            }
        }
    }

    /// Momentary brightening of the weapon light on firing — a cheap, readable
    /// bounce that makes the muzzle flash feel like it lights the world.
    func pulseWeaponLight(_ amount: Float) {
        guard let light = weaponLight.light else { return }
        light.intensity = CGFloat(weaponLightBase * (1 + amount))
    }

    func settleWeaponLight(dt: Float) {
        guard let light = weaponLight.light else { return }
        light.intensity = CGFloat(damp(Float(light.intensity), weaponLightBase, 9, dt))
    }

    // MARK: Projection

    /// World point -> normalised device coordinates, or nil when behind the
    /// camera. Shared by the HUD, the simulated player and — most importantly —
    /// the enemy visibility gate, so all three agree on what is on screen.
    func project(_ world: SIMD3<Float>, aspect: Float) -> SIMD2<Float>? {
        guard let cam = cameraNode.camera else { return nil }
        let inv = simd_inverse(cameraNode.simdWorldTransform)
        let v4 = inv * SIMD4(world, 1)
        let v = SIMD3(v4.x, v4.y, v4.z)
        guard v.z < -0.05 else { return nil }
        let tanHalfV = tan(Float(cam.fieldOfView) * .pi / 180 / 2)
        let tanHalfH = tanHalfV * aspect
        return SIMD2((v.x / -v.z) / tanHalfH, (v.y / -v.z) / tanHalfV)
    }

    // MARK: Queries

    var cameraPosition: SIMD3<Float> { cameraNode.simdPosition }

    /// Forward axis of the camera in world space (SceneKit cameras look down -Z).
    var cameraForward: SIMD3<Float> {
        cameraNode.simdOrientation.act(SIMD3(0, 0, -1))
    }
}
