import Foundation
import SceneKit
import simd

/// Maps a free-roaming world position back onto the level's authored rail.
///
/// The rail is no longer a track the camera rides — it is now the level's
/// *spine*. Projecting the player onto it yields "how far through the level am
/// I", which is what every encounter trigger, the objective marker and the
/// progress bar are written against. That is what lets the original five level
/// scripts survive the move to free movement unchanged.
struct RailProjector {
    /// Polyline samples of the spline: position plus arc distance at that point.
    private var points: [SIMD3<Float>] = []
    private var distances: [Float] = []
    let totalLength: Float

    init(spline: Spline, step: Float = 1.0) {
        totalLength = spline.totalLength
        var d: Float = 0
        while d < spline.totalLength {
            points.append(spline.position(atDistance: d))
            distances.append(d)
            d += step
        }
        points.append(spline.position(atDistance: spline.totalLength))
        distances.append(spline.totalLength)
    }

    struct Projection {
        /// Arc distance along the rail of the closest point.
        var distance: Float
        /// The closest point itself.
        var point: SIMD3<Float>
        /// Signed lateral offset; positive is to the right of travel.
        var lateral: Float
        /// Unit tangent at that point.
        var forward: SIMD3<Float>
    }

    /// Nearest point on the rail polyline.
    ///
    /// `hint` restricts the search to a window around a previous result, and
    /// matters more than it looks: levels 2 and 4 loop back on themselves, so
    /// their paths pass within a few metres of their own start. A purely global
    /// search snapped the player from 114 m back to 4 m as they neared the exit,
    /// which re-armed every encounter and hung the level. Searching near where
    /// the player already was makes progress monotonic and is faster besides.
    func project(_ world: SIMD3<Float>, hint: Float? = nil, window: Float = 22) -> Projection {
        guard points.count >= 2 else {
            return Projection(distance: 0, point: world, lateral: 0, forward: SIMD3(0, 0, 1))
        }
        var lo = 0, hi = points.count - 2
        if let hint {
            // distances[] is monotonic, so the window maps to an index range.
            lo = max(0, indexBefore(hint - window))
            hi = min(points.count - 2, indexBefore(hint + window))
            if hi < lo { hi = lo }
        }

        var bestD2 = Float.greatestFiniteMagnitude
        var bestIndex = lo
        var bestT: Float = 0

        let q = SIMD2<Float>(world.x, world.z)
        for i in lo...hi {
            let a = SIMD2(points[i].x, points[i].z)
            let b = SIMD2(points[i + 1].x, points[i + 1].z)
            let ab = b - a
            let len2 = simd_length_squared(ab)
            let t = len2 > 1e-6 ? clamp01(simd_dot(q - a, ab) / len2) : 0
            let closest = a + ab * t
            let d2 = simd_distance_squared(closest, q)
            if d2 < bestD2 { bestD2 = d2; bestIndex = i; bestT = t }
        }

        let a = points[bestIndex], b = points[bestIndex + 1]
        let p = simd_mix(a, b, SIMD3(repeating: bestT))
        let dist = lerp(distances[bestIndex], distances[bestIndex + 1], bestT)
        let fwd = (b - a).flat.normalizedSafe
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), fwd))
        let lateral = simd_dot(world - p, right)
        return Projection(distance: dist, point: p, lateral: lateral, forward: fwd)
    }

    /// Index of the last polyline sample at or before a given arc distance.
    private func indexBefore(_ d: Float) -> Int {
        guard !distances.isEmpty else { return 0 }
        if d <= 0 { return 0 }
        if d >= totalLength { return points.count - 2 }
        var lo = 0, hi = distances.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if distances[mid] <= d { lo = mid } else { hi = mid }
        }
        return min(lo, points.count - 2)
    }

    /// World point at a rail distance and lateral offset — the authoring
    /// coordinate system the level scripts use for spawns.
    func worldPoint(distance: Float, lateral: Float, height: Float = 0) -> SIMD3<Float> {
        guard points.count >= 2 else { return SIMD3(lateral, height, distance) }
        let d = clamp(distance, 0, totalLength)
        var i = 0
        while i < distances.count - 2 && distances[i + 1] < d { i += 1 }
        let span = max(distances[i + 1] - distances[i], 1e-4)
        let t = clamp01((d - distances[i]) / span)
        let p = simd_mix(points[i], points[i + 1], SIMD3(repeating: t))
        let fwd = (points[i + 1] - points[i]).flat.normalizedSafe
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), fwd))
        return p + right * lateral + SIMD3(0, height, 0)
    }

    func forward(atDistance d: Float) -> SIMD3<Float> {
        guard points.count >= 2 else { return SIMD3(0, 0, 1) }
        let dd = clamp(d, 0, totalLength)
        var i = 0
        while i < distances.count - 2 && distances[i + 1] < dd { i += 1 }
        return (points[i + 1] - points[i]).flat.normalizedSafe
    }
}

/// Movement collision against the level's static geometry.
///
/// A full physics body would be overkill for a walking character on flat-ish
/// ground: what is actually needed is "do not walk through walls, and slide
/// along them instead of sticking". Three short ray casts a frame does that, and
/// costs a fraction of adding rigid bodies to every prop in the level.
struct CollisionWorld {
    private let root: SCNNode
    /// Radius of the player's collision cylinder.
    let radius: Float = 0.42
    /// Height at which walls are probed — hip height, so kerbs and rubble at
    /// ankle level do not block movement but a wall does.
    private let probeHeights: [Float] = [0.55, 1.25]

    init(root: SCNNode) {
        self.root = root
    }

    private static let options: [String: Any] = [
        SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
        SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
        SCNHitTestOption.backFaceCulling.rawValue: false
    ]

    /// First obstruction between two points at a given height, if any.
    private func blocker(from: SIMD3<Float>, to: SIMD3<Float>, height: Float)
        -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        let a = SIMD3(from.x, from.y + height, from.z)
        let b = SIMD3(to.x, to.y + height, to.z)
        guard let hit = root.hitTestWithSegment(from: a.scn, to: b.scn, options: CollisionWorld.options).first
        else { return nil }
        return (hit.worldCoordinates.simd, hit.worldNormal.simd)
    }

    /// Moves from `from` toward `to`, sliding along anything in the way.
    /// Returns the position actually reached.
    func resolve(from: SIMD3<Float>, to: SIMD3<Float>) -> SIMD3<Float> {
        let delta = (to - from).flat
        let dist = simd_length(delta)
        guard dist > 1e-5 else { return from }

        if !isBlocked(from: from, delta: delta) { return from + delta }

        // Blocked head-on. Try sliding along the surface, then along both
        // tangents. Giving up after a single rejection makes props feel like
        // glue — the simulated player wedged itself on a wrecked car and pressed
        // into it for the remaining eight minutes of the level.
        var candidates: [SIMD3<Float>] = []
        if let n = surfaceNormal(from: from, delta: delta) {
            let into = simd_dot(delta, n)
            if into < 0 { candidates.append(delta - n * into) }
        }
        let dir = delta / dist
        let tangent = SIMD3<Float>(-dir.z, 0, dir.x)
        for scale in [Float(1.0), 0.7] {
            candidates.append(tangent * dist * scale)
            candidates.append(-tangent * dist * scale)
        }
        for c in candidates where simd_length(c) > 1e-5 {
            if !isBlocked(from: from, delta: c) { return from + c }
        }
        return from
    }

    private func isBlocked(from: SIMD3<Float>, delta: SIMD3<Float>) -> Bool {
        let d = simd_length(delta)
        guard d > 1e-5 else { return false }
        // Probe beyond the destination so the player stops a body-radius short of
        // the wall rather than with their nose against it.
        let to = from + delta / d * (d + radius)
        for h in probeHeights where blocker(from: from, to: to, height: h) != nil { return true }
        return false
    }

    private func surfaceNormal(from: SIMD3<Float>, delta: SIMD3<Float>) -> SIMD3<Float>? {
        let d = simd_length(delta)
        guard d > 1e-5 else { return nil }
        let to = from + delta / d * (d + radius)
        for h in probeHeights {
            if let hit = blocker(from: from, to: to, height: h) {
                let n = hit.normal.flat
                if simd_length_squared(n) > 1e-6 { return simd_normalize(n) }
            }
        }
        return nil
    }
}
