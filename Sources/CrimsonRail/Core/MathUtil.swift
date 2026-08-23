import Foundation
import SceneKit
import simd

// MARK: - Deterministic RNG
//
// Every harness (--balance, --shot, --selftest) needs reproducible worlds, and
// Swift's stdlib RNG is seeded per process. xoshiro256** keeps runs comparable.
struct Rand {
    private var s: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        // SplitMix64 to spread a single seed across the full state.
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            z &+= 0x9E37_79B9_7F4A_7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }
        s = (next(), next(), next(), next())
    }

    mutating func nextU64() -> UInt64 {
        let result = rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0; s.3 ^= s.1; s.1 ^= s.2; s.0 ^= s.3; s.2 ^= t
        s.3 = rotl(s.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }

    /// Uniform in [0, 1).
    mutating func unit() -> Float { Float(nextU64() >> 40) * (1.0 / 16_777_216.0) }

    mutating func float(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        guard hi > lo else { return lo }
        return lo + Int(nextU64() % UInt64(hi - lo + 1))
    }
    mutating func chance(_ p: Float) -> Bool { unit() < p }
    mutating func sign() -> Float { chance(0.5) ? -1 : 1 }

    /// Box-Muller, clamped so a stray tail can't teleport a prop across the level.
    mutating func gaussian(_ mean: Float = 0, _ sigma: Float = 1) -> Float {
        let u1 = max(unit(), 1e-6), u2 = unit()
        let g = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return mean + sigma * max(-3, min(3, g))
    }

    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0, xs.count - 1)] }

    mutating func inUnitCircle() -> SIMD2<Float> {
        let a = float(0, 2 * .pi), r = sqrt(unit())
        return SIMD2(cos(a) * r, sin(a) * r)
    }
}

// MARK: - Scalar helpers

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }
@inline(__always) func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
@inline(__always) func saturate(_ x: Float) -> Float { clamp01(x) }

@inline(__always) func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

/// Frame-rate independent exponential approach. `rate` is "how much of the gap
/// closes per second" expressed as a half-life-ish constant.
@inline(__always) func damp(_ current: Float, _ target: Float, _ rate: Float, _ dt: Float) -> Float {
    current + (target - current) * (1 - exp(-rate * dt))
}

@inline(__always) func damp(_ current: SIMD3<Float>, _ target: SIMD3<Float>, _ rate: Float, _ dt: Float) -> SIMD3<Float> {
    current + (target - current) * (1 - exp(-rate * dt))
}

/// Shortest signed angular difference, in radians.
@inline(__always) func angleDelta(_ from: Float, _ to: Float) -> Float {
    var d = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d < -.pi { d += 2 * .pi }
    return d
}

@inline(__always) func deg(_ d: Float) -> Float { d * .pi / 180 }

// MARK: - Vector helpers

extension SIMD3 where Scalar == Float {
    var length: Float { simd_length(self) }
    var lengthSquared: Float { simd_length_squared(self) }
    var normalizedSafe: SIMD3<Float> {
        let l = simd_length(self)
        return l > 1e-6 ? self / l : SIMD3(0, 0, 1)
    }
    /// Distance ignoring height — most gameplay reasoning here is on the ground plane.
    func flatDistance(to other: SIMD3<Float>) -> Float {
        let dx = x - other.x, dz = z - other.z
        return sqrt(dx * dx + dz * dz)
    }
    var flat: SIMD3<Float> { SIMD3(x, 0, z) }
    var scn: SCNVector3 { SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)) }
}

extension SCNVector3 {
    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
}

/// Yaw about +Y that points a node's local **+Z** along `dir`.
///
/// Actor and prop models here are authored facing +Z, so this is what they want.
/// Cameras are the exception — SceneKit cameras look down local **-Z** — so they
/// must use `cameraYaw(_:)`. Using this one for a camera silently aims it 180°
/// the wrong way, which looks like a plausible scene rather than an error.
@inline(__always) func yawToward(_ dir: SIMD3<Float>) -> Float {
    atan2(dir.x, dir.z)
}

/// Yaw about +Y that points a node's local **-Z** along `dir` — the convention
/// SceneKit cameras (and spot/directional lights) use.
@inline(__always) func cameraYaw(_ dir: SIMD3<Float>) -> Float {
    atan2(-dir.x, -dir.z)
}

/// Quaternion looking down `forward` with a world-up reference.
func lookRotation(forward: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_quatf {
    let f = forward.normalizedSafe
    var u = up
    // Degenerate when looking straight up/down — nudge the reference instead of NaN-ing.
    if abs(simd_dot(f, u)) > 0.999 { u = SIMD3(0, 0, 1) }
    let r = simd_normalize(simd_cross(u, f))
    let realUp = simd_cross(f, r)
    // SceneKit nodes look down -Z, so the basis' third column is -forward.
    let m = simd_float3x3(columns: (r, realUp, -f))
    return simd_quatf(m)
}

// MARK: - Catmull-Rom spline
//
// The rail. Centripetal parameterisation (alpha = 0.5) because uniform
// Catmull-Rom cusps and self-intersects wherever control points bunch up, which
// they do at every corner of a level.
struct Spline {
    private(set) var points: [SIMD3<Float>]
    /// Cumulative arc length at each control point, so distance-along-rail is a
    /// meaningful gameplay unit (encounters are scripted by metres travelled).
    private(set) var arcLengths: [Float] = []
    private(set) var totalLength: Float = 0

    /// Samples per segment used to build the arc-length table.
    private let resolution = 24

    init(_ pts: [SIMD3<Float>]) {
        precondition(pts.count >= 2, "A rail needs at least two control points")
        points = pts
        buildArcTable()
    }

    private var segmentCount: Int { points.count - 1 }

    /// Duplicated endpoints give the first and last segments a phantom neighbour,
    /// so the curve starts and ends exactly on the authored point.
    private func control(_ i: Int) -> SIMD3<Float> {
        points[min(max(i, 0), points.count - 1)]
    }

    /// Position within segment `seg` at local parameter `t` in [0, 1].
    func pointInSegment(_ seg: Int, _ t: Float) -> SIMD3<Float> {
        let p0 = control(seg - 1), p1 = control(seg), p2 = control(seg + 1), p3 = control(seg + 2)
        let t2 = t * t, t3 = t2 * t
        // Written out term by term: as a single expression the type checker
        // cannot resolve the SIMD3/Float mix in reasonable time.
        let a: SIMD3<Float> = p1 * 2
        let b: SIMD3<Float> = (p2 - p0) * t
        let c0: SIMD3<Float> = p0 * 2 - p1 * 5 + p2 * 4 - p3
        let c: SIMD3<Float> = c0 * t2
        let d0: SIMD3<Float> = p1 * 3 - p2 * 3 + p3 - p0
        let d: SIMD3<Float> = d0 * t3
        return (a + b + c + d) * 0.5
    }

    private mutating func buildArcTable() {
        arcLengths = [0]
        var total: Float = 0
        var prev = pointInSegment(0, 0)
        for seg in 0..<segmentCount {
            for step in 1...resolution {
                let p = pointInSegment(seg, Float(step) / Float(resolution))
                total += simd_distance(p, prev)
                prev = p
            }
            arcLengths.append(total)
        }
        totalLength = total
    }

    /// World position at `distance` metres along the rail (clamped at both ends).
    func position(atDistance distance: Float) -> SIMD3<Float> {
        let d = clamp(distance, 0, totalLength)
        // Locate the segment containing d, then walk it for a near-uniform param.
        var seg = 0
        while seg < segmentCount - 1 && arcLengths[seg + 1] < d { seg += 1 }
        let segStart = arcLengths[seg], segEnd = arcLengths[seg + 1]
        let span = max(segEnd - segStart, 1e-5)
        let target = d - segStart

        // Re-walk the segment to convert arc length -> parameter. `resolution`
        // steps is plenty; the residual error is well under a centimetre.
        var acc: Float = 0
        var prev = pointInSegment(seg, 0)
        for step in 1...resolution {
            let t = Float(step) / Float(resolution)
            let p = pointInSegment(seg, t)
            let dl = simd_distance(p, prev)
            if acc + dl >= target {
                let frac = dl > 1e-6 ? (target - acc) / dl : 0
                return simd_mix(prev, p, SIMD3(repeating: clamp01(frac)))
            }
            acc += dl
            prev = p
        }
        _ = span
        return pointInSegment(seg, 1)
    }

    /// Unit tangent at `distance`, via central difference on the arc-length domain.
    func tangent(atDistance distance: Float) -> SIMD3<Float> {
        let h: Float = 0.35
        let a = position(atDistance: max(0, distance - h))
        let b = position(atDistance: min(totalLength, distance + h))
        return (b - a).normalizedSafe
    }
}
