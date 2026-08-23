import Foundation
import SceneKit
import AppKit
import simd

/// A shootable region of a body, expressed as a capsule in a joint's local space.
///
/// Hit detection is analytic rather than `hitTestWithSegment`: the ray is
/// transformed into each joint's local frame and tested against a capsule. That
/// gives exact control over which zone wins a tie (the head always does), works
/// with no view attached — so the headless harnesses can fire real shots — and
/// costs a few hundred cheap tests per trigger pull.
struct HitPart {
    var node: SCNNode
    var zone: HitZone
    var radius: Float
    /// Capsule segment endpoints along the joint's local Y axis.
    var y0: Float
    var y1: Float
    /// Limbs can be shot off; a torso cannot.
    var severable: Bool
    /// Set once the limb has been removed, so it stops absorbing bullets.
    var detached = false
}

/// The assembled node hierarchy for one creature, plus the joints the animator
/// poses and the parts the combat system shoots at.
///
/// Every archetype is built from the same rig but a different body: the Runner
/// is stripped and sinewy, the Brute is a wall of plated muscle, the Spitter is
/// bloated, the Crawler is broken. Silhouette does the work of telling them
/// apart, because at fifteen metres in the dark it is all the player has.
final class ZombieBody {
    let root = SCNNode()

    // Joints. Every one rotates about its own origin, so the geometry beneath is
    // offset rather than the joint itself.
    let hips = SCNNode()
    let chest = SCNNode()
    let neck = SCNNode()
    let head = SCNNode()
    var upperArm: [SCNNode] = []      // [left, right]
    var lowerArm: [SCNNode] = []
    var thigh: [SCNNode] = []
    var shin: [SCNNode] = []

    private(set) var parts: [HitPart] = []
    /// Emissive eye nodes, dimmed on death.
    private(set) var eyes: [SCNNode] = []
    /// Boss weak points; empty for ordinary enemies.
    private(set) var weakPoints: [SCNNode] = []

    let kind: ZombieKind
    let isCivilian: Bool
    let scale: Float
    /// Standing height, used to aim attacks and place damage effects.
    private(set) var standHeight: Float = 1.8
    /// Local Y of the hip joint at rest; the animator offsets from this.
    private(set) var hipsRestY: Float = 0.94

    // Proportions, in metres at scale 1.
    private var hipY: Float = 0.92
    private var spineLen: Float = 0.30
    private var chestLen: Float = 0.32
    private var neckLen: Float = 0.10
    private var upperArmLen: Float = 0.31
    private var lowerArmLen: Float = 0.28
    private var thighLen: Float = 0.44
    private var shinLen: Float = 0.42
    private var shoulderW: Float = 0.23
    private var hipW: Float = 0.12
    /// Vertical offset from the hip joint down to the hip sockets.
    private let hipOffsetY: Float = 0.12
    /// Sole-to-ankle height, so the feet rest on the ground rather than in it.
    private let ankleHeight: Float = 0.075
    /// 0 = well fed, 1 = skeletal. Drives rib definition and waist pinch.
    private var emaciation: Float = 0.5
    /// Muscle belly on the limbs; low for withered types.
    private var limbBulge: Float = 0.16

    private var detail: Anatomy.Detail = .normal

    /// `civilian` reuses the same rig for a living person: intact palette, no
    /// glowing eyes. Survivors must never be mistaken for a target.
    init(kind: ZombieKind, seed: UInt64, civilian: Bool = false) {
        self.isCivilian = civilian
        self.kind = kind
        let stats = kind.stats
        self.scale = stats.scale
        var rng = Rand(seed: seed)

        // Per-instance proportion jitter, plus a deliberate asymmetry: one
        // shoulder rides higher and one arm is longer. Symmetry is the thing that
        // reads as "manufactured", and the dead are not symmetrical.
        thighLen *= rng.float(0.93, 1.07)
        shinLen *= rng.float(0.93, 1.07)
        upperArmLen *= rng.float(0.92, 1.10)
        lowerArmLen *= rng.float(0.92, 1.10)
        shoulderW *= rng.float(0.92, 1.12)
        chestLen *= rng.float(0.93, 1.08)
        emaciation = rng.float(0.35, 0.85)

        applyArchetype(rng: &rng)
        // Hip height is not an independent number: it is whatever puts the soles
        // on the ground. Jittering it separately from the limb lengths buried the
        // feet six centimetres under the floor.
        hipY = hipOffsetY + thighLen + shinLen + ankleHeight
        if civilian {
            emaciation = 0.25
            limbBulge = 0.18
            detail = .normal
        }

        build(rng: &rng, stats: stats)
        hipsRestY = hipY
        root.simdScale = SIMD3(repeating: scale)
        standHeight = (hipY + spineLen + chestLen + neckLen + 0.24) * scale
    }

    /// Silhouette and build per archetype. This is where the six enemies stop
    /// being palette swaps and become different creatures.
    private func applyArchetype(rng: inout Rand) {
        switch kind {
        case .shambler:
            // The everyman: office or funeral clothes, moderately decayed.
            limbBulge = 0.15
            detail = .normal

        case .runner:
            // Stripped and sinewy. Long stride, ribs out, nothing left on it.
            emaciation = rng.float(0.80, 1.0)
            limbBulge = 0.07
            shoulderW *= 0.92
            thighLen *= 1.06
            shinLen *= 1.06
            detail = .normal

        case .crawler:
            // Broken below the waist: withered legs, over-developed arms.
            emaciation = rng.float(0.70, 0.95)
            limbBulge = 0.10
            upperArmLen *= 1.22
            lowerArmLen *= 1.22
            thighLen *= 0.74
            shinLen *= 0.70
            shoulderW *= 1.12
            detail = .normal

        case .brute:
            // A wall. Huge through the shoulders, tiny head sunk between them.
            emaciation = rng.float(0.05, 0.25)
            limbBulge = 0.34
            shoulderW *= 1.55
            chestLen *= 1.18
            upperArmLen *= 1.10
            lowerArmLen *= 1.08
            detail = .normal

        case .spitter:
            // Bloated: distended belly and a swollen throat sac over thin limbs.
            emaciation = rng.float(0.0, 0.15)
            limbBulge = 0.05
            shoulderW *= 0.90
            detail = .normal

        case .warden:
            // Seen up close for minutes at a time, so it earns the extra rings.
            emaciation = rng.float(0.10, 0.30)
            limbBulge = 0.32
            shoulderW *= 1.65
            chestLen *= 1.25
            detail = .hero
        }
    }

    // MARK: Construction

    private func build(rng: inout Rand, stats: ZombieStats) {
        let mats = MaterialLibrary.shared
        let flesh: SCNMaterial
        let cloth: SCNMaterial
        let bone: SCNMaterial
        if isCivilian {
            flesh = mats.solid(NSColor(rgb: 0.36, 0.28, 0.23), roughness: 0.72)
            cloth = mats.solid(NSColor(rgb: 0.30, 0.34, 0.40), roughness: 0.9)
            bone = mats.solid(NSColor(rgb: 0.55, 0.52, 0.45), roughness: 0.6)
        } else {
            flesh = mats.pbr(.rottenFlesh(hue: stats.fleshHue), tiling: 3.4,
                             seed: UInt64(stats.fleshHue), roughnessScale: 1)
            cloth = mats.pbr(.rags(hue: stats.ragHue), tiling: 3.8, seed: UInt64(stats.ragHue))
            bone = mats.solid(NSColor(rgb: 0.52, 0.49, 0.42), roughness: 0.45)
        }
        let darkRecess = mats.solid(NSColor(rgb: 0.020, 0.016, 0.016), roughness: 0.95)
        let toothMat = mats.solid(NSColor(rgb: 0.62, 0.58, 0.47), roughness: 0.4)

        // A faint self-illumination keeps the creature separable from a very dark
        // background without lighting the whole level.
        if let rim = kind.rimColor, !isCivilian {
            flesh.emission.contents = rim
            flesh.emission.intensity = 0.09
        }

        root.name = "zombie"
        root.addChildNode(hips)
        hips.simdPosition = SIMD3(0, hipY, 0)

        // ---- Pelvis ----------------------------------------------------------
        var pelvisMesh = MeshBuilder()
        Anatomy.pelvis(into: &pelvisMesh, width: shoulderW * 0.92, riseTo: spineLen,
                       emaciation: emaciation, detail: detail)
        hips.addChildNode(pelvisMesh.node(material: flesh))

        hips.addChildNode(chest)
        chest.simdPosition = SIMD3(0, spineLen, 0)

        // ---- Torso -----------------------------------------------------------
        var torsoMesh = MeshBuilder()
        let torsoSections = Anatomy.torso(into: &torsoMesh, height: chestLen, shoulderWidth: shoulderW,
                                          emaciation: emaciation, detail: detail, rng: &rng)
        // The spitter's swollen gut, blended onto the front of the torso.
        if kind == .spitter {
            var gut = MeshBuilder()
            gut.addLoft([
                .init(SIMD3(0, -0.05, 0.02), shoulderW * 0.50, shoulderW * 0.44),
                .init(SIMD3(0, 0.06, 0.07), shoulderW * 0.74, shoulderW * 0.68),
                .init(SIMD3(0, 0.20, 0.06), shoulderW * 0.66, shoulderW * 0.56),
            ], segments: detail.ring, capStart: true, capEnd: true)
            torsoMesh.append(gut)
        }
        chest.addChildNode(torsoMesh.node(material: flesh))

        // Clothing, as a separate shell so flesh shows through the tears.
        if let outfit = clothing(torso: torsoSections, rng: &rng) {
            var shirt = MeshBuilder()
            Anatomy.clothShell(into: &shirt, sections: outfit.sections,
                               thickness: outfit.thickness, tear: outfit.tear,
                               detail: detail, rng: &rng)
            let node = shirt.node(material: cloth)
            node.name = "cloth"
            chest.addChildNode(node)
        }

        // Exposed ribs on the types whose chest is bare.
        // Only on the types that wear nothing over the chest — otherwise the
        // bone pokes straight through the shirt.
        if !isCivilian && (kind == .runner || kind == .crawler) {
            var ribs = MeshBuilder()
            Anatomy.exposedRibs(into: &ribs, height: chestLen, width: shoulderW,
                                count: rng.int(4, 6), rng: &rng)
            chest.addChildNode(ribs.node(material: bone))
        }

        // Bolted plate for the armoured types. Reads at a glance as "not here".
        if kind == .brute || kind == .warden {
            var armour = MeshBuilder()
            armour.addLoft([
                .init(SIMD3(0, chestLen * 0.12, 0.02), shoulderW * 0.74, shoulderW * 0.52),
                .init(SIMD3(0, chestLen * 0.52, 0.02), shoulderW * 0.86, shoulderW * 0.58),
                .init(SIMD3(0, chestLen * 0.86, 0.01), shoulderW * 0.76, shoulderW * 0.50),
            ], segments: detail.ring, capStart: false, capEnd: false)
            // Rivets around the rim, driven into the flesh beneath.
            for i in 0..<detail.ring {
                let a = Float(i) / Float(detail.ring) * 2 * .pi
                for y in [chestLen * 0.16, chestLen * 0.82] as [Float] {
                    let r = shoulderW * 0.80
                    armour.addBox(center: SIMD3(cos(a) * r, y, sin(a) * r * 0.68),
                                  size: SIMD3(0.026, 0.026, 0.026))
                }
            }
            // Pauldrons.
            for s in [-1, 1] as [Float] {
                armour.addLoft([
                    .init(SIMD3(s * shoulderW * 0.74, chestLen * 0.94, 0), shoulderW * 0.30, shoulderW * 0.30),
                    .init(SIMD3(s * shoulderW * 0.86, chestLen * 0.80, 0), shoulderW * 0.34, shoulderW * 0.32),
                    .init(SIMD3(s * shoulderW * 0.92, chestLen * 0.62, 0), shoulderW * 0.22, shoulderW * 0.22),
                ], segments: max(detail.ring - 2, 6), capStart: true, capEnd: true)
            }
            chest.addChildNode(armour.node(material: mats.pbr(.rustedMetal, tiling: 4.5, seed: 3,
                                                              metalness: 0.9,
                                                              tint: NSColor(rgb: 0.30, 0.27, 0.25))))
        }

        chest.addChildNode(neck)
        neck.simdPosition = SIMD3(0, chestLen, 0)
        // Neck itself, so the head is not floating on a gap.
        var neckMesh = MeshBuilder()
        Anatomy.limb(into: &neckMesh, length: -neckLen, topRadius: shoulderW * 0.30,
                     bottomRadius: shoulderW * 0.26, bulge: 0, flatten: 0.9,
                     detail: detail, rng: &rng)
        neck.addChildNode(neckMesh.node(material: flesh))

        neck.addChildNode(head)
        head.simdPosition = SIMD3(0, neckLen, 0)
        buildHead(rng: &rng, flesh: flesh, bone: bone, recess: darkRecess, tooth: toothMat)

        // ---- Arms -------------------------------------------------------------
        for side in [-1, 1] as [Float] {
            // Asymmetry: one shoulder sits higher than the other.
            let drop = side < 0 ? rng.float(0, 0.035) : rng.float(0, 0.035)
            let upper = SCNNode()
            upper.simdPosition = SIMD3(side * shoulderW * 0.92, chestLen * 0.86 - drop, 0)
            chest.addChildNode(upper)

            var upperMesh = MeshBuilder()
            // Deltoid cap, then the upper arm proper.
            upperMesh.addLoft([
                .init(SIMD3(0, 0.03, 0), 0.070, 0.066),
                .init(SIMD3(0, -0.02, 0), 0.082, 0.076),
            ], segments: detail.ring, capStart: true, capEnd: false)
            Anatomy.limb(into: &upperMesh, length: upperArmLen, topRadius: 0.076,
                         bottomRadius: 0.058, bulge: limbBulge, flatten: 0.92,
                         detail: detail, rng: &rng)
            upper.addChildNode(upperMesh.node(material: flesh))

            let lower = SCNNode()
            lower.simdPosition = SIMD3(0, -upperArmLen, 0)
            upper.addChildNode(lower)
            var lowerMesh = MeshBuilder()
            Anatomy.limb(into: &lowerMesh, length: lowerArmLen, topRadius: 0.062,
                         bottomRadius: 0.036, bulge: limbBulge * 0.7, flatten: 0.86,
                         detail: detail, rng: &rng)
            lower.addChildNode(lowerMesh.node(material: flesh))

            // Hand, or a bone stump where one has been torn off.
            let handNode = SCNNode()
            handNode.simdPosition = SIMD3(0, -lowerArmLen, 0)
            lower.addChildNode(handNode)
            if !isCivilian && rng.chance(0.12) {
                var stump = MeshBuilder()
                Anatomy.boneStump(into: &stump, radius: 0.036, length: 0.075)
                handNode.addChildNode(stump.node(material: bone))
            } else {
                var handMesh = MeshBuilder()
                Anatomy.hand(into: &handMesh, detail: detail, rng: &rng,
                             scale: kind == .brute || kind == .warden ? 1.25 : 1.0,
                             curl: kind == .crawler ? 0.15 : rng.float(0.35, 0.7))
                handNode.addChildNode(handMesh.node(material: flesh))
            }

            upperArm.append(upper)
            lowerArm.append(lower)
            parts.append(HitPart(node: upper, zone: .arm, radius: 0.095, y0: 0.03, y1: -upperArmLen, severable: true))
            parts.append(HitPart(node: lower, zone: .arm, radius: 0.078, y0: 0, y1: -lowerArmLen - 0.09, severable: true))
        }

        // ---- Legs -------------------------------------------------------------
        for side in [-1, 1] as [Float] {
            let th = SCNNode()
            th.simdPosition = SIMD3(side * hipW, -0.12, 0)
            hips.addChildNode(th)
            var thighMesh = MeshBuilder()
            Anatomy.limb(into: &thighMesh, length: thighLen, topRadius: 0.115,
                         bottomRadius: 0.078, bulge: limbBulge, flatten: 0.94,
                         detail: detail, rng: &rng)
            th.addChildNode(thighMesh.node(material: flesh))

            let sh = SCNNode()
            sh.simdPosition = SIMD3(0, -thighLen, 0)
            th.addChildNode(sh)
            var shinMesh = MeshBuilder()
            // Calf belly high on the shin, tapering hard to a thin ankle.
            Anatomy.limb(into: &shinMesh, length: shinLen, topRadius: 0.082,
                         bottomRadius: 0.040, bulge: limbBulge * 1.2, flatten: 0.90,
                         detail: detail, rng: &rng)
            sh.addChildNode(shinMesh.node(material: flesh))

            var footMesh = MeshBuilder()
            Anatomy.foot(into: &footMesh, detail: detail, scale: 1)
            let footNode = footMesh.node(material: rng.chance(0.45) ? flesh : cloth)
            // The foot mesh puts its sole at y = 0.010, so the ankle sits at
            // -shinLen and the sole lands exactly on the ground plane.
            footNode.simdPosition = SIMD3(0, -shinLen - ankleHeight + 0.010, 0)
            sh.addChildNode(footNode)

            // Trousers, cut to hug the leg rather than hang off it. Sections
            // track the limb's own taper; a shell much wider than the leg reads
            // as a bell-bottomed skirt.
            if kind != .runner && !(kind == .crawler && rng.chance(0.5)) {
                let tear = rng.float(0.12, 0.42)
                var leg = MeshBuilder()
                Anatomy.clothShell(into: &leg, sections: [
                    .init(SIMD3(0, 0.01, 0), 0.114, 0.106),
                    .init(SIMD3(0, -thighLen * 0.50, 0), 0.094, 0.088),
                    .init(SIMD3(0, -thighLen * 0.97, 0), 0.078, 0.074),
                ], thickness: 0.010, tear: tear, detail: detail, rng: &rng)
                th.addChildNode(leg.node(material: cloth))

                // Below the knee, unless the trouser is torn off at the thigh.
                if tear < 0.34 {
                    var lower = MeshBuilder()
                    Anatomy.clothShell(into: &lower, sections: [
                        .init(SIMD3(0, 0.0, 0), 0.082, 0.078),
                        .init(SIMD3(0, -shinLen * 0.55, 0), 0.060, 0.056),
                        .init(SIMD3(0, -shinLen * 0.92, 0), 0.046, 0.044),
                    ], thickness: 0.009, tear: rng.float(0.1, 0.4), detail: detail, rng: &rng)
                    sh.addChildNode(lower.node(material: cloth))
                }
            }

            thigh.append(th)
            shin.append(sh)
            parts.append(HitPart(node: th, zone: .leg, radius: 0.125, y0: 0, y1: -thighLen, severable: false))
            parts.append(HitPart(node: sh, zone: .leg, radius: 0.098, y0: 0, y1: -shinLen, severable: true))
        }

        // Torso and head hit zones. Ordered last but resolved by priority.
        parts.append(HitPart(node: hips, zone: .torso, radius: 0.215, y0: -0.17, y1: spineLen, severable: false))
        parts.append(HitPart(node: chest, zone: .torso, radius: shoulderW * 0.95, y0: -0.03, y1: chestLen, severable: false))
        parts.append(HitPart(node: head, zone: .head, radius: 0.125, y0: -0.02, y1: 0.15, severable: false))

        if kind == .warden && !isCivilian { buildWeakPoints() }
    }

    /// Clothing cut per archetype, derived from the torso's own cross-sections so
    /// it always encloses the body. Returns nil for types that wear nothing.
    private func clothing(torso: [MeshBuilder.LoftSection], rng: inout Rand)
        -> (sections: [MeshBuilder.LoftSection], thickness: Float, tear: Float)? {
        // `torso` runs waist -> lower ribs -> mid chest -> upper chest ->
        // shoulder line -> neck base.
        func slice(_ range: ClosedRange<Int>) -> [MeshBuilder.LoftSection] {
            Array(torso[range.clamped(to: 0...(torso.count - 1))])
        }
        switch kind {
        case .runner:
            return nil                                   // stripped to the waist
        case .crawler:
            // A few rags still clinging to the shoulders.
            return (slice(2...4), 0.020, rng.float(0.55, 0.85))
        case .brute, .warden:
            return nil                                   // the plate is the clothing
        case .spitter:
            // A gown, hanging off the shoulders over the swollen gut.
            return (slice(0...4), 0.028, rng.float(0.30, 0.55))
        case .shambler:
            // A shirt from the waist to the shoulder line.
            return (slice(0...4), 0.022, rng.float(0.20, 0.55))
        }
    }

    private func buildHead(rng: inout Rand, flesh: SCNMaterial, bone: SCNMaterial,
                           recess: SCNMaterial, tooth: SCNMaterial) {
        let mats = MaterialLibrary.shared
        // The brute's head is small and sunk between its shoulders; the spitter's
        // is wide-jawed; the runner's is drawn tight over the skull.
        let headScale: Float = {
            switch kind {
            case .brute: return 0.86
            case .warden: return 0.80
            case .spitter: return 1.10
            case .runner: return 0.95
            default: return 1.0
            }
        }()

        var skullMesh = MeshBuilder()
        Anatomy.skull(into: &skullMesh, detail: detail, rng: &rng, scale: headScale)
        head.addChildNode(skullMesh.node(material: flesh))

        var socketMesh = MeshBuilder()
        var teethMesh = MeshBuilder()
        Anatomy.faceDetail(sockets: &socketMesh, teeth: &teethMesh,
                           detail: detail, rng: &rng, scale: headScale)
        head.addChildNode(socketMesh.node(material: recess))
        if !teethMesh.isEmpty {
            head.addChildNode(teethMesh.node(material: tooth))
        }

        // Scalp: a patchy remnant of hair, or nothing at all.
        if !isCivilian && rng.chance(0.55) {
            var hair = MeshBuilder()
            let n = rng.int(3, 6)
            for _ in 0..<n {
                let a = rng.float(0, 2 * .pi)
                let r = rng.float(0.02, 0.06) * headScale
                hair.addLoft([
                    .init(SIMD3(cos(a) * r, 0.120 * headScale, sin(a) * r), 0.030 * headScale, 0.030 * headScale),
                    .init(SIMD3(cos(a) * r * 1.1, 0.152 * headScale, sin(a) * r * 1.1), 0.022 * headScale, 0.022 * headScale),
                ], segments: 5, capStart: false, capEnd: true)
            }
            head.addChildNode(hair.node(material: mats.solid(NSColor(rgb: 0.055, 0.045, 0.038), roughness: 0.95)))
        }

        // An iron half-mask over the Warden's face, leaving the jaw exposed.
        if kind == .warden {
            var mask = MeshBuilder()
            mask.addLoft([
                .init(SIMD3(0, 0.030, 0) * headScale, 0.092 * headScale, 0.100 * headScale),
                .init(SIMD3(0, 0.100, -0.004) * headScale, 0.094 * headScale, 0.102 * headScale),
                .init(SIMD3(0, 0.150, -0.012) * headScale, 0.062 * headScale, 0.070 * headScale),
            ], segments: detail.ring, capStart: false, capEnd: true)
            head.addChildNode(mask.node(material: mats.pbr(.rustedMetal, tiling: 8, seed: 5,
                                                           metalness: 0.9,
                                                           tint: NSColor(rgb: 0.26, 0.24, 0.22))))
        }

        // Eyes: small, and set *deep* in the sockets so they read as points of
        // light in a hollow rather than as beads stuck on a face.
        let eyeColor: NSColor = isCivilian
            ? NSColor(rgb: 0.05, 0.04, 0.04)
            : (kind == .warden ? NSColor(rgb: 1.0, 0.22, 0.10) : NSColor(rgb: 1.0, 0.68, 0.24))
        for s in [-1, 1] as [Float] {
            let eye = SCNNode(geometry: SCNSphere(radius: CGFloat(0.0135 * headScale)))
            eye.geometry?.materials = [isCivilian
                ? mats.solid(eyeColor, roughness: 0.5)
                : mats.glow(eyeColor, intensity: kind == .warden ? 2.6 : 1.5)]
            eye.simdPosition = SIMD3(s * 0.040, 0.050, 0.052) * headScale
            eye.castsShadow = false
            head.addChildNode(eye)
            eyes.append(eye)
        }
    }

    private func buildWeakPoints() {
        let mats = MaterialLibrary.shared
        // Exposed, glowing tissue between armour plates. Only these take damage,
        // so they must be large enough to hit under pressure.
        // Placed proud of the torso hit capsule (radius `shoulderW * 0.95`).
        // Sunk inside it, the chest intercepts every shot aimed at them and the
        // boss becomes unkillable — which is exactly what the balance run caught.
        let front = shoulderW * 1.02
        let spots: [(SIMD3<Float>, Float)] = [
            (SIMD3(-0.17, chestLen * 0.42, front), 0.042),
            (SIMD3(0.17, chestLen * 0.42, front), 0.042),
            (SIMD3(0, chestLen * 0.88, front * 0.88), 0.036),
        ]
        for (pos, r) in spots {
            // A torn gap in the plate, with lit tissue at the bottom of it. The
            // visual has to stay small or it reads as a button glued to the
            // chest; the *hit* radius is generously larger so it is still fair to
            // shoot while the thing is moving.
            // The socket sits *behind* the glow as a dark halo. Enclosing the
            // glow in it simply hides the thing the player is meant to shoot.
            let socket = SCNNode(geometry: SCNSphere(radius: CGFloat(r * 1.35)))
            socket.geometry?.materials = [mats.solid(NSColor(rgb: 0.045, 0.020, 0.016), roughness: 0.9)]
            socket.simdPosition = pos - SIMD3(0, 0, r * 1.15)
            socket.castsShadow = false
            chest.addChildNode(socket)

            let n = SCNNode(geometry: SCNSphere(radius: CGFloat(r)))
            n.geometry?.materials = [mats.glow(NSColor(rgb: 0.95, 0.20, 0.06), intensity: 1.6)]
            n.simdPosition = pos
            n.castsShadow = false
            n.name = "weakpoint"
            chest.addChildNode(n)
            weakPoints.append(n)
            parts.append(HitPart(node: n, zone: .head, radius: r * 3.4, y0: 0, y1: 0, severable: false))
        }
    }

    // MARK: Damage feedback

    func setEyeGlow(_ intensity: Float) {
        for e in eyes {
            e.geometry?.firstMaterial?.emission.intensity = CGFloat(intensity)
        }
    }

    func pulseWeakPoints(_ t: Float) {
        guard !weakPoints.isEmpty else { return }
        let v = 0.95 + sin(t * 3.4) * 0.45
        for w in weakPoints {
            w.geometry?.firstMaterial?.emission.intensity = CGFloat(v)
        }
    }

    /// Removes a limb and returns its node so the caller can turn it into a
    /// falling gib. Marks every hit part under it detached.
    @discardableResult
    func sever(partIndex: Int) -> SCNNode? {
        guard parts.indices.contains(partIndex), parts[partIndex].severable,
              !parts[partIndex].detached else { return nil }
        let node = parts[partIndex].node
        // Anything hanging off the severed joint goes with it.
        for i in parts.indices where !parts[i].detached {
            if parts[i].node === node || parts[i].node.isDescendant(of: node) {
                parts[i].detached = true
            }
        }
        let world = node.simdWorldTransform
        node.removeFromParentNode()
        node.simdTransform = world

        // Leave a bone stub behind, so a severed limb reads as torn off rather
        // than as a missing model part.
        if let parent = node.parent {
            var stump = MeshBuilder()
            Anatomy.boneStump(into: &stump, radius: 0.040, length: 0.070)
            let s = stump.node(material: MaterialLibrary.shared.solid(
                NSColor(rgb: 0.42, 0.16, 0.14), roughness: 0.55))
            s.simdPosition = node.simdPosition
            parent.addChildNode(s)
        }
        return node
    }

    // MARK: Ray tests

    /// Closest hit along the ray, or nil. Head wins ties within a small margin so
    /// a shot that grazes both the head and a shoulder counts as a headshot.
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float) -> (index: Int, t: Float)? {
        var best: (index: Int, t: Float)?
        var bestHeadT: Float?
        var bestHeadIndex: Int?
        for (i, part) in parts.enumerated() {
            guard !part.detached, part.node.parent != nil else { continue }
            guard let t = ZombieBody.rayCapsule(origin: origin, direction: direction,
                                                node: part.node, radius: part.radius,
                                                y0: part.y0, y1: part.y1),
                  t >= 0, t <= maxDistance else { continue }
            if part.zone == .head {
                if bestHeadT == nil || t < bestHeadT! { bestHeadT = t; bestHeadIndex = i }
            }
            if best == nil || t < best!.t { best = (i, t) }
        }
        // A head or weak-point hit outranks a torso hit on the same body by a
        // generous margin. On a wide enemy the torso capsule reaches well in
        // front of the head, so a tight margin quietly turns headshots into body
        // shots — and on the boss, whose torso is armoured, into no damage at all.
        if let h = bestHeadT, let hi = bestHeadIndex, let b = best,
           h <= b.t + (parts[b.index].zone == .torso ? 0.9 : 0.25) {
            return (hi, h)
        }
        return best
    }

    /// Ray against a capsule expressed in a node's local space.
    static func rayCapsule(origin: SIMD3<Float>, direction: SIMD3<Float>,
                           node: SCNNode, radius: Float, y0: Float, y1: Float) -> Float? {
        let world = node.simdWorldTransform
        let inv = simd_inverse(world)
        let lo = inv * SIMD4(origin, 1)
        let ld = inv * SIMD4(direction, 0)
        let o = SIMD3(lo.x, lo.y, lo.z)
        var d = SIMD3(ld.x, ld.y, ld.z)
        let dLen = simd_length(d)
        guard dLen > 1e-6 else { return nil }
        d /= dLen

        let a = SIMD3<Float>(0, min(y0, y1), 0)
        let b = SIMD3<Float>(0, max(y0, y1), 0)
        guard let tLocal = segmentCapsuleT(o: o, d: d, a: a, b: b, r: radius) else { return nil }
        // Convert the local-space parameter back to world distance.
        return tLocal / dLen
    }

    /// Analytic ray-vs-capsule. Returns the parameter along a unit-length `d`.
    private static func segmentCapsuleT(o: SIMD3<Float>, d: SIMD3<Float>,
                                        a: SIMD3<Float>, b: SIMD3<Float>, r: Float) -> Float? {
        let ba = b - a
        let baLen2 = simd_length_squared(ba)
        if baLen2 < 1e-9 {
            return raySphereT(o: o, d: d, c: a, r: r)
        }
        let oa = o - a
        let baDotD = simd_dot(ba, d)
        let baDotOA = simd_dot(ba, oa)

        // Infinite-cylinder test, restricted to the segment, then sphere caps.
        let A = baLen2 - baDotD * baDotD
        let B = baLen2 * simd_dot(oa, d) - baDotOA * baDotD
        let C = baLen2 * simd_length_squared(oa) - baDotOA * baDotOA - r * r * baLen2

        var best: Float?
        if abs(A) > 1e-9 {
            let disc = B * B - A * C
            if disc >= 0 {
                let t = (-B - sqrt(disc)) / A
                let y = baDotOA + t * baDotD
                if t >= 0, y >= 0, y <= baLen2 { best = t }
            }
        }
        for cap in [a, b] {
            if let t = raySphereT(o: o, d: d, c: cap, r: r) {
                if best == nil || t < best! { best = t }
            }
        }
        return best
    }

    private static func raySphereT(o: SIMD3<Float>, d: SIMD3<Float>, c: SIMD3<Float>, r: Float) -> Float? {
        let oc = o - c
        let b = simd_dot(oc, d)
        let cc = simd_length_squared(oc) - r * r
        let disc = b * b - cc
        guard disc >= 0 else { return nil }
        let t = -b - sqrt(disc)
        return t >= 0 ? t : nil
    }
}

extension SCNNode {
    func isDescendant(of other: SCNNode) -> Bool {
        var p = parent
        while let node = p {
            if node === other { return true }
            p = node.parent
        }
        return false
    }
}
