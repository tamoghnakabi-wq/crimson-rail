import Foundation
import SceneKit
import simd

/// Reusable body parts, built from lofted cross-sections.
///
/// The previous models were capsules on a stick, which is why they read as
/// mannequins: a capsule has no shoulders, no brow, no wrist and no calf. Every
/// part here is specified by its silhouette instead, because silhouette is what
/// survives being seen at fifteen metres in the dark, which is how this game is
/// actually played.
enum Anatomy {

    /// Level of detail. Ordinary enemies get `.normal`; the boss, which is seen
    /// close and for a long time, gets `.hero`.
    enum Detail {
        case low, normal, hero
        var ring: Int {
            switch self { case .low: return 7; case .normal: return 10; case .hero: return 14 }
        }
        var fingerRing: Int {
            switch self { case .low: return 3; case .normal: return 4; case .hero: return 5 }
        }
        var wantsFingers: Bool { self != .low }
        var wantsTeeth: Bool { self != .low }
    }

    // MARK: - Head

    /// A skull with a cranium, brow ridge, cheekbones, a nasal hollow and a jaw.
    ///
    /// Built as a loft whose radius is modulated per ring and per segment: that
    /// modulation is the whole face. Segment 0 faces +Z (forward), so the front
    /// of the head is around index 0 and the back is around `segments/2`.
    static func skull(into m: inout MeshBuilder, detail: Detail, rng: inout Rand,
                      scale: Float = 1) {
        let seg = detail.ring
        // Cross-sections from the neck stump up over the crown.
        let sections: [MeshBuilder.LoftSection] = [
            .init(SIMD3(0, -0.055, 0.004) * scale, 0.052 * scale, 0.056 * scale),  // neck stump
            .init(SIMD3(0, -0.012, 0.008) * scale, 0.070 * scale, 0.076 * scale),  // jaw line
            .init(SIMD3(0, 0.030, 0.010) * scale, 0.083 * scale, 0.092 * scale),   // cheekbones
            .init(SIMD3(0, 0.068, 0.006) * scale, 0.088 * scale, 0.097 * scale),   // brow
            .init(SIMD3(0, 0.104, -0.002) * scale, 0.086 * scale, 0.094 * scale),  // forehead
            .init(SIMD3(0, 0.140, -0.010) * scale, 0.070 * scale, 0.078 * scale),  // crown
            .init(SIMD3(0, 0.166, -0.016) * scale, 0.034 * scale, 0.040 * scale),  // top
        ]
        // Per-ring, per-segment modulation. `front` is 1 at +Z and 0 at -Z.
        let jitter = (0..<seg).map { _ in rng.float(0.97, 1.03) }
        m.addLoft(sections, segments: seg, capStart: true, capEnd: true, uvScale: 1) { si, sg in
            let a = Float(sg) / Float(seg) * 2 * .pi
            let front = (cos(a) + 1) * 0.5
            let side = abs(sin(a))
            var mul: Float = jitter[sg]
            switch si {
            case 1:
                // Jaw: narrow at the front into a chin, and undercut at the sides.
                mul *= 0.90 + front * 0.16 - side * 0.06
            case 2:
                // Cheekbones flare sideways; the face is flatter than the skull.
                mul *= 0.94 + side * 0.12 - front * 0.05
            case 3:
                // Brow ridge: a hard shelf at the front.
                mul *= 0.96 + front * front * 0.16
            case 4:
                mul *= 0.99 + front * 0.03
            case 5:
                mul *= 1.0 - front * 0.04
            default:
                break
            }
            return mul
        }

        // Nasal hollow: a small inward dent above the jaw.
        var nose = MeshBuilder()
        nose.addLoft([
            .init(SIMD3(0, 0.020, 0.070) * scale, 0.016 * scale, 0.012 * scale),
            .init(SIMD3(0, 0.048, 0.082) * scale, 0.020 * scale, 0.016 * scale),
            .init(SIMD3(0, 0.062, 0.070) * scale, 0.012 * scale, 0.010 * scale),
        ], segments: max(detail.ring - 4, 5), capStart: true, capEnd: true)
        m.append(nose)
    }

    /// The recessed parts of a face: sockets, teeth, and a hanging jaw. Returned
    /// separately so they can take darker, harder materials than skin.
    static func faceDetail(sockets: inout MeshBuilder, teeth: inout MeshBuilder,
                           detail: Detail, rng: inout Rand, scale: Float = 1) {
        // Eye sockets: cones driven back into the skull. A recess reads as a
        // sunken eye; a sphere on the surface reads as a doll.
        for s in [-1, 1] as [Float] {
            let x = s * 0.040 * scale
            sockets.addLoft([
                .init(SIMD3(x, 0.052, 0.074) * scale, 0.026 * scale, 0.021 * scale),
                .init(SIMD3(x, 0.050, 0.050) * scale, 0.021 * scale, 0.017 * scale),
                .init(SIMD3(x * 0.9, 0.048, 0.028) * scale, 0.008 * scale, 0.007 * scale),
            ], segments: max(detail.ring - 4, 5), capStart: true, capEnd: true)
        }

        guard detail.wantsTeeth else { return }
        // A row of uneven teeth on each jaw. Individually they are specks; as a
        // row they are the difference between a face and a mask.
        for s in stride(from: -0.030, through: 0.030, by: 0.0125) {
            let w = Float(0.0052) * scale
            let h = rng.float(0.008, 0.014) * scale
            teeth.addBox(center: SIMD3(Float(s) * scale, (0.004 - h * 0.5), 0.062 * scale),
                         size: SIMD3(w, h, 0.010 * scale))
            teeth.addBox(center: SIMD3(Float(s) * scale, (-0.020 + h * 0.4), 0.058 * scale),
                         size: SIMD3(w, h * 0.8, 0.010 * scale))
        }
    }

    // MARK: - Limbs

    /// A limb segment with a muscle belly: thicker a third of the way down,
    /// tapering to the joint. `bulge` 0 gives a plain taper (withered limbs).
    static func limb(into m: inout MeshBuilder, length: Float,
                     topRadius: Float, bottomRadius: Float,
                     bulge: Float = 0.16, flatten: Float = 1.0,
                     detail: Detail, rng: inout Rand) {
        let steps = 5
        var sections: [MeshBuilder.LoftSection] = []
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let base = lerp(topRadius, bottomRadius, t)
            // Belly peaks around a third of the way along.
            let belly = 1 + bulge * sin(clamp01(t / 0.75) * .pi) * rng.float(0.85, 1.15)
            let r = base * belly
            sections.append(.init(SIMD3(0, -length * t, 0), r, r * flatten))
        }
        m.addLoft(sections, segments: detail.ring, capStart: true, capEnd: true, uvScale: 1)
    }

    /// A hand: palm plus tapered fingers and an opposed thumb.
    ///
    /// Fingers are the single biggest readability win on a reaching enemy — a
    /// clubbed stump at the end of an outstretched arm is what made the old
    /// models read as shop dummies.
    static func hand(into m: inout MeshBuilder, detail: Detail, rng: inout Rand,
                     scale: Float = 1, curl: Float = 0.45) {
        let s = scale
        // Palm: a flattened box-ish loft.
        m.addLoft([
            .init(SIMD3(0, 0, 0), 0.030 * s, 0.016 * s),
            .init(SIMD3(0, -0.030 * s, 0.002 * s), 0.034 * s, 0.017 * s),
            .init(SIMD3(0, -0.062 * s, 0.004 * s), 0.031 * s, 0.015 * s),
        ], segments: detail.ring, capStart: true, capEnd: true)

        guard detail.wantsFingers else { return }
        // Four fingers, curled forward by `curl`. Lengths vary like a real hand.
        let lengths: [Float] = [0.052, 0.058, 0.054, 0.044]
        for (i, len) in lengths.enumerated() {
            let x = (Float(i) - 1.5) * 0.019 * s
            var sections: [MeshBuilder.LoftSection] = []
            let joints = 3
            var p = SIMD3<Float>(x, -0.060 * s, 0.006 * s)
            var dir = SIMD3<Float>(0, -1, 0.15)
            for j in 0...joints {
                let t = Float(j) / Float(joints)
                let r = (0.0085 - 0.0030 * t) * s * rng.float(0.9, 1.1)
                sections.append(.init(p, r, r * 0.85))
                // Curl: each joint bends the finger further toward the palm.
                let bend = curl * (0.55 + t * 0.8) * rng.float(0.85, 1.15)
                dir = simd_normalize(dir + SIMD3(0, 0, bend * 0.55) + SIMD3(0, bend * 0.10, 0))
                p += dir * (len * s / Float(joints))
            }
            m.addLoft(sections, segments: detail.fingerRing, capStart: true, capEnd: true)
        }
        // Thumb, set off to one side and rotated across the palm.
        var tp = SIMD3<Float>(0.030 * s, -0.022 * s, 0.008 * s)
        var tdir = SIMD3<Float>(0.55, -0.72, 0.42)
        var tsections: [MeshBuilder.LoftSection] = []
        for j in 0...2 {
            let t = Float(j) / 2
            let r = (0.0100 - 0.0032 * t) * s
            tsections.append(.init(tp, r, r * 0.9))
            tdir = simd_normalize(tdir + SIMD3(0, 0, curl * 0.5))
            tp += tdir * (0.024 * s)
        }
        m.addLoft(tsections, segments: detail.fingerRing, capStart: true, capEnd: true)
    }

    /// A foot: heel, arch and a splayed toe box.
    static func foot(into m: inout MeshBuilder, detail: Detail, scale: Float = 1) {
        let s = scale
        m.addLoft([
            .init(SIMD3(0, 0.048 * s, -0.026 * s), 0.030 * s, 0.030 * s),   // ankle
            .init(SIMD3(0, 0.024 * s, -0.030 * s), 0.034 * s, 0.038 * s),   // heel
            .init(SIMD3(0, 0.014 * s, 0.010 * s), 0.036 * s, 0.055 * s),    // arch
            .init(SIMD3(0, 0.012 * s, 0.062 * s), 0.040 * s, 0.045 * s),    // ball
            .init(SIMD3(0, 0.010 * s, 0.092 * s), 0.032 * s, 0.020 * s),    // toes
        ], segments: max(detail.ring - 2, 6), capStart: true, capEnd: true)
    }

    // MARK: - Torso

    /// Ribcage tapering to a waist, with shoulder mass. `emaciation` pinches the
    /// waist and sharpens the ribs.
    @discardableResult
    static func torso(into m: inout MeshBuilder, height: Float, shoulderWidth: Float,
                      emaciation: Float, detail: Detail, rng: inout Rand) -> [MeshBuilder.LoftSection] {
        let w = shoulderWidth
        let jitter = (0..<detail.ring).map { _ in rng.float(0.97, 1.03) }
        let sections: [MeshBuilder.LoftSection] = [
            .init(SIMD3(0, -0.02, 0), w * 0.62, w * 0.44),                    // waist
            .init(SIMD3(0, height * 0.26, 0.004), w * 0.66, w * 0.47),        // lower ribs
            .init(SIMD3(0, height * 0.55, 0.006), w * 0.80, w * 0.52),        // mid chest
            .init(SIMD3(0, height * 0.80, 0.002), w * 0.92, w * 0.53),        // upper chest
            .init(SIMD3(0, height * 0.97, -0.004), w * 0.86, w * 0.48),       // shoulder line
            .init(SIMD3(0, height * 1.06, -0.010), w * 0.44, w * 0.34),       // neck base
        ]
        m.addLoft(sections, segments: detail.ring, capStart: true, capEnd: true, uvScale: 1) { si, sg in
            let a = Float(sg) / Float(detail.ring) * 2 * .pi
            let front = (cos(a) + 1) * 0.5
            let side = abs(sin(a))
            var mul = jitter[sg]
            // A starved torso is hollow at the front and shows its ribs at the sides.
            if si == 0 { mul *= 1 - emaciation * 0.14 * front }
            if si == 1 || si == 2 { mul *= 1 + emaciation * 0.05 * side - emaciation * 0.07 * front }
            // Trapezius: build the shoulders up at the sides, not the front.
            if si == 4 { mul *= 0.92 + side * 0.20 }
            return mul
        }
        // Hand back the widest radius each section reaches, so a garment built
        // from these is guaranteed to sit outside the body rather than inside it.
        return sections.enumerated().map { i, sec in
            let flare: Float = (i == 4) ? 1.12 : 1.04
            return MeshBuilder.LoftSection(sec.center, sec.radiusX * flare, sec.radiusZ * flare)
        }
    }

    /// Exposed ribs, as slats across the chest. Placed over a torso whose
    /// clothing has been torn away.
    static func exposedRibs(into m: inout MeshBuilder, height: Float, width: Float,
                            count: Int, rng: inout Rand) {
        for i in 0..<count {
            let t = Float(i) / Float(max(count - 1, 1))
            let y = height * (0.30 + t * 0.42)
            let halfW = width * (0.36 - t * 0.05)
            let droop = 0.012 + t * 0.006
            // Each rib is a shallow arc across the front of the chest.
            var prev = SIMD3<Float>(-halfW, y, width * 0.16)
            let steps = 4
            for k in 1...steps {
                let u = Float(k) / Float(steps)
                let x = lerp(-halfW, halfW, u)
                let bow = sin(u * .pi)
                let p = SIMD3(x, y - droop * (1 - bow), width * (0.16 + bow * 0.16))
                Props.addOrientedTube(&m, from: prev, to: p,
                                      r0: 0.010 * rng.float(0.85, 1.15),
                                      r1: 0.010, segments: 4)
                prev = p
            }
        }
        // Sternum.
        Props.addOrientedTube(&m, from: SIMD3(0, height * 0.28, width * 0.30),
                              to: SIMD3(0, height * 0.76, width * 0.30),
                              r0: 0.016, r1: 0.013, segments: 5)
    }

    /// Pelvis and abdomen, as one form running from the hip crests up to meet
    /// the ribcage.
    ///
    /// `riseTo` must reach the chest joint: modelling the pelvis as an isolated
    /// lump leaves a visible gap at the waist and the upper body reads as
    /// floating above the legs.
    static func pelvis(into m: inout MeshBuilder, width: Float, riseTo: Float,
                       emaciation: Float, detail: Detail) {
        let waist = width * (0.56 - emaciation * 0.10)
        m.addLoft([
            .init(SIMD3(0, -0.17, 0), width * 0.50, width * 0.38),
            .init(SIMD3(0, -0.08, 0.004), width * 0.64, width * 0.45),
            .init(SIMD3(0, 0.01, 0.006), width * 0.70, width * 0.47),   // hip crests
            .init(SIMD3(0, riseTo * 0.45, 0.004), waist, waist * 0.72),  // waist
            .init(SIMD3(0, riseTo * 0.92, 0.002), waist * 1.06, waist * 0.76),
        ], segments: detail.ring, capStart: true, capEnd: true, uvScale: 1)
    }

    /// A shell that sits just outside another form — a shirt over a chest, or
    /// trousers over a thigh — with a torn, uneven hem.
    ///
    /// Clothing as separate geometry rather than a texture is what lets flesh
    /// show through the gaps, which is most of what makes a zombie look damaged
    /// rather than merely dirty.
    static func clothShell(into m: inout MeshBuilder, sections: [MeshBuilder.LoftSection],
                           thickness: Float, tear: Float, detail: Detail, rng: inout Rand) {
        var grown = sections.map {
            MeshBuilder.LoftSection($0.center, $0.radiusX + thickness, $0.radiusZ + thickness, twist: $0.twist)
        }
        // Ragged hem: pull the last ring down unevenly.
        if var last = grown.last, tear > 0 {
            last.center.y -= tear * rng.float(0.08, 0.24)
            grown[grown.count - 1] = last
        }
        let ring = detail.ring
        let hem = (0..<ring).map { _ in rng.float(0, 1) }
        m.addLoft(grown, segments: ring, capStart: false, capEnd: false, uvScale: 1) { si, sg in
            // Only the hem ring is ragged, and it is pushed *out*, never in.
            // Shrinking the shell to suggest a tear simply buries it inside the
            // torso, which is why the shirts were invisible.
            guard si == grown.count - 1 else { return 1 }
            return 1 + hem[sg] * tear * 0.10
        }
    }

    /// Bone stub left behind when a limb is torn off.
    static func boneStump(into m: inout MeshBuilder, radius: Float, length: Float) {
        m.addLoft([
            .init(SIMD3(0, 0, 0), radius * 0.9, radius * 0.9),
            .init(SIMD3(0, -length * 0.6, 0), radius * 0.34, radius * 0.34),
            .init(SIMD3(0, -length, 0), radius * 0.26, radius * 0.26),
        ], segments: 6, capStart: true, capEnd: true)
    }
}
