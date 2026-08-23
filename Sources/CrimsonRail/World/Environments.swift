import Foundation
import SceneKit
import AppKit
import simd

/// The assembled world for one level.
struct BuiltLevel {
    var root: SCNNode
    var spline: Spline
    var fogColor: NSColor
    var fogStart: Float
    var fogEnd: Float
    var fogDensityExponent: Float = 1.6
    var background: NSColor
    /// Nodes that flicker (candles, failing fluorescents, fires).
    var flickerLights: [FlickerLight] = []
    /// Ambient bed identifier for the audio director.
    var ambience: AmbienceKind = .wind
    /// Half-width of the walkable band around the level's spine. The player is
    /// clamped to this; geometry collision handles everything inside it.
    var corridorHalfWidth: Float = 6
    /// Surface height at a world position. Actors and decals sample this so
    /// they sit on the ground instead of hovering above or sinking into it.
    var groundHeight: (SIMD3<Float>) -> Float = { _ in 0 }
    /// The level's key directional light, and the direction it shines. The
    /// playfield re-anchors it to the camera every frame so its shadow frustum
    /// always covers the play area.
    var keyLightNode: SCNNode? = nil
    var keyLightDirection: SIMD3<Float> = SIMD3(0.5, -0.7, 0.4)
    /// Half-extent of the key light's shadow frustum, in metres.
    var keyLightRange: Float = 34
    /// Tint for the player's weapon light, which keeps enemies readable in the dark.
    var weaponLightColor: NSColor = NSColor(rgb: 1.0, 0.93, 0.82)
    var weaponLightIntensity: Float = 900
}

struct FlickerLight {
    var node: SCNNode
    var baseIntensity: Float
    var speed: Float
    var depth: Float
    /// Fluorescents cut out entirely; flames only waver.
    var isFailing: Bool
    var seed: Float
}

enum AmbienceKind {
    case wind, interior, fire, machinery, storm
}

// MARK: - Shared construction helpers

enum EnvBuild {
    static var mats: MaterialLibrary { .shared }

    /// Ribbon of ground following the rail — reads as a worn path and tells the
    /// player where the camera is going before it gets there.
    static func pathRibbon(spline: Spline, width: Float, kind: TextureKind,
                           tiling: Float, seed: UInt64, yOffset: Float = 0.012) -> SCNNode {
        var m = MeshBuilder()
        let step: Float = 1.2
        var d: Float = 0
        var prevL = SIMD3<Float>.zero, prevR = SIMD3<Float>.zero
        var first = true
        var rng = Rand(seed: seed)
        while d <= spline.totalLength {
            let p = spline.position(atDistance: d)
            let f = spline.tangent(atDistance: d)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let halfW = width / 2 * rng.float(0.88, 1.12)
            let l = p - r * halfW + SIMD3(0, yOffset, 0)
            let rr = p + r * halfW + SIMD3(0, yOffset, 0)
            if !first {
                // Wound so the visible face points up. Traced the other way round
                // the ribbon is back-face culled and the level simply has no floor.
                m.addQuad(prevL, l, rr, prevR, uvScale: 1, normal: SIMD3(0, 1, 0))
            }
            prevL = l; prevR = rr; first = false
            d += step
        }
        let n = m.node(material: mats.pbr(kind, tiling: tiling, seed: seed), name: "path")
        n.castsShadow = false
        return n
    }

    /// Walks the rail and calls `place` at intervals with a rail-relative frame.
    /// Everything laterally inside `corridor` is skipped so the player's line of
    /// travel and sight stays clear.
    static func scatterAlongRail(spline: Spline, from: Float = 0, to: Float? = nil,
                                 step: Float, lateralRange: ClosedRange<Float>, corridor: Float,
                                 seed: UInt64, density: Float = 1,
                                 place: (_ position: SIMD3<Float>, _ yaw: Float, _ rng: inout Rand, _ index: Int) -> Void) {
        var rng = Rand(seed: seed)
        let end = to ?? spline.totalLength
        var d = from
        var index = 0
        while d < end {
            defer { d += step }
            if rng.unit() > density { continue }
            let p = spline.position(atDistance: d)
            let f = spline.tangent(atDistance: d)
            let r = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            for side in [-1, 1] as [Float] {
                if rng.unit() > density { continue }
                let lat = rng.float(lateralRange.lowerBound, lateralRange.upperBound)
                guard lat >= corridor else { continue }
                let jitterZ = rng.float(-step * 0.4, step * 0.4)
                let pos = p + r * (lat * side) + f * jitterZ
                place(pos, rng.float(0, 2 * .pi), &rng, index)
                index += 1
            }
        }
    }

    /// Builds a ground-height lookup that follows the rail.
    ///
    /// Interior and stair levels climb; a single flat plane leaves actors standing
    /// well below (or above) the player, where they cannot be seen, shot, or
    /// meaningfully fought. Sampling the spline into a coarse grid and taking the
    /// nearest sample is accurate to a few centimetres and costs nothing per query.
    static func railHeightField(spline: Spline, floorOffset: Float = 0) -> (SIMD3<Float>) -> Float {
        var samples: [(p: SIMD2<Float>, y: Float)] = []
        var d: Float = 0
        while d <= spline.totalLength + 2 {
            let p = spline.position(atDistance: min(d, spline.totalLength))
            samples.append((SIMD2(p.x, p.z), p.y + floorOffset))
            d += 1.5
        }
        return { query in
            var bestY = samples.first?.y ?? floorOffset
            var bestD = Float.greatestFiniteMagnitude
            let q = SIMD2(query.x, query.z)
            for s in samples {
                let dd = simd_distance_squared(s.p, q)
                if dd < bestD { bestD = dd; bestY = s.y }
            }
            return bestY
        }
    }

    /// Merges a container's children into as few draw calls as SceneKit can manage.
    /// Static dressing only — flattening discards node identity and animation.
    static func flatten(_ node: SCNNode, castsShadow: Bool = true) -> SCNNode {
        let flat = node.flattenedClone()
        flat.castsShadow = castsShadow
        flat.enumerateChildNodes { child, _ in child.castsShadow = castsShadow }
        return flat
    }

    /// Shared setup for a level's key directional light.
    ///
    /// Two SceneKit behaviours are worked around here, and both present as "the
    /// key light does nothing":
    ///
    /// 1. `automaticallyAdjustsShadowProjection` did not produce a frustum
    ///    covering a level this long. Everything outside it sampled as fully
    ///    shadowed — measurably so with *no shadow casters in the scene at all* —
    ///    so the ground stayed black while lit props looked correct.
    /// 2. The deferred shadow pass is screen-space and streaks across a large,
    ///    gently curved ground mesh at the shallow angles a moon produces.
    ///
    /// The projection is therefore explicit, and the caller re-anchors the light
    /// to the camera each frame (see `Playfield.anchorKeyLight`).
    static func configureKeyShadow(_ light: SCNLight, quality: GraphicsSettings, range: Float) {
        light.castsShadow = quality.shadowsEnabled
        guard light.castsShadow else { return }
        light.shadowMapSize = CGSize(width: quality.shadowMapSize, height: quality.shadowMapSize)
        light.shadowMode = .forward
        light.shadowSampleCount = quality.preset == .ultra ? 16 : 8
        light.shadowRadius = 3
        light.shadowBias = CGFloat(DebugFlags.shadowBias ?? 5)
        light.automaticallyAdjustsShadowProjection = false
        light.orthographicScale = CGFloat(range)
        light.zNear = 1
        light.zFar = CGFloat(range * 3.2)
        light.shadowCascadeCount = 1
    }

    /// Point light with sensible falloff for a dark interior.
    static func lamp(color: NSColor, intensity: Float, range: Float,
                     castsShadow: Bool, quality: GraphicsSettings) -> SCNNode {
        let light = SCNLight()
        light.type = .omni
        light.color = color
        light.intensity = CGFloat(intensity)
        light.attenuationStartDistance = CGFloat(range * 0.15)
        light.attenuationEndDistance = CGFloat(range)
        light.castsShadow = castsShadow && quality.shadowsEnabled
        if light.castsShadow {
            light.shadowMapSize = CGSize(width: quality.shadowMapSize / 2, height: quality.shadowMapSize / 2)
            light.shadowMode = .deferred
            light.shadowRadius = 3
            light.shadowSampleCount = quality.preset == .ultra ? 16 : 8
            light.shadowColor = NSColor(white: 0, alpha: 0.75)
        }
        let n = SCNNode()
        n.light = light
        return n
    }

    /// A visible glowing bulb plus its light.
    ///
    /// The bulb is a *sibling* of the light, not a child: distance culling hides
    /// the light node, and a bulb parented to it would pop out of existence along
    /// with it while still being plainly in view.
    static func practicalLight(color: NSColor, intensity: Float, range: Float, bulbRadius: Float,
                               castsShadow: Bool, quality: GraphicsSettings) -> SCNNode {
        let container = SCNNode()
        let n = lamp(color: color, intensity: intensity, range: range, castsShadow: castsShadow, quality: quality)
        container.addChildNode(n)
        let bulb = SCNNode(geometry: SCNSphere(radius: CGFloat(bulbRadius)))
        bulb.geometry?.materials = [mats.glow(color, intensity: 2.5)]
        bulb.castsShadow = false
        container.addChildNode(bulb)
        return container
    }
}

// MARK: - Environment dispatch

enum Environments {
    static func build(_ def: LevelDef, quality: GraphicsSettings) -> BuiltLevel {
        let spline = Spline(def.railPoints)
        switch def.environment {
        case .cemetery: return buildCemetery(def, spline: spline, quality: quality)
        case .manor: return buildManor(def, spline: spline, quality: quality)
        case .street: return buildStreet(def, spline: spline, quality: quality)
        case .lab: return buildLab(def, spline: spline, quality: quality)
        case .spire: return buildSpire(def, spline: spline, quality: quality)
        }
    }
}
