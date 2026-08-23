import Foundation

/// Environment-variable overrides for isolating rendering problems.
///
///   CR_SKIP=shadows,fog,particles,sky,bloom,ao,weaponlight,props
///
/// Bisecting a "the scene is too dark / too bright / wrong" bug by toggling one
/// contributor at a time is far faster than reasoning about the combination.
enum DebugFlags {
    private static let skips: Set<String> = {
        guard let raw = ProcessInfo.processInfo.environment["CR_SKIP"] else { return [] }
        return Set(raw.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }()

    static func skip(_ name: String) -> Bool { skips.contains(name) }

    static var noShadows: Bool { skip("shadows") }
    static var noFog: Bool { skip("fog") }
    static var noParticles: Bool { skip("particles") }
    static var noSky: Bool { skip("sky") }
    static var noBloom: Bool { skip("bloom") }
    static var noAO: Bool { skip("ao") }
    static var noWeaponLight: Bool { skip("weaponlight") }
    static var noProps: Bool { skip("props") }

    /// CR_BIAS=4 overrides the key light's shadow bias while tuning it.
    static var shadowBias: Float? {
        guard let raw = ProcessInfo.processInfo.environment["CR_BIAS"], let v = Float(raw) else { return nil }
        return v
    }

    /// CR_LIGHT=2.0 scales every level light, for finding an exposure baseline.
    static var lightScale: Float {
        guard let raw = ProcessInfo.processInfo.environment["CR_LIGHT"], let v = Float(raw) else { return 1 }
        return v
    }
}
