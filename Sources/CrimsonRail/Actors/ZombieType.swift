import Foundation
import AppKit
import simd

enum ZombieKind: String, CaseIterable, Codable {
    /// The baseline: slow, tough enough to need two body shots, telegraphs hard.
    case shambler
    /// Fast and fragile. Punishes players who linger on an easy target.
    case runner
    /// Low to the ground and quick — forces the crosshair off head height.
    case crawler
    /// Armoured torso; body shots ricochet, so it must be headshot or flanked.
    case brute
    /// Hangs back and spits acid. The projectile itself is shootable.
    case spitter
    /// Level-5 finale. Multi-phase, exposed weak points between attacks.
    case warden

    var displayName: String {
        switch self {
        case .shambler: return "Shambler"
        case .runner: return "Runner"
        case .crawler: return "Crawler"
        case .brute: return "Brute"
        case .spitter: return "Spitter"
        case .warden: return "The Warden"
        }
    }

    var stats: ZombieStats {
        switch self {
        case .shambler:
            return ZombieStats(
                maxHealth: 46, moveSpeed: 1.55, damage: 10, attackReach: 2.0,
                windup: 0.88, recovery: 1.15, scale: 1.0,
                headMultiplier: 3.4, torsoMultiplier: 1.0, limbMultiplier: 0.62,
                torsoArmor: 0, staggerResistance: 0.25, baseScore: 100,
                fleshHue: 1, ragHue: 1)
        case .runner:
            return ZombieStats(
                maxHealth: 30, moveSpeed: 4.35, damage: 9, attackReach: 1.9,
                windup: 0.50, recovery: 0.85, scale: 0.97,
                headMultiplier: 3.6, torsoMultiplier: 1.0, limbMultiplier: 0.6,
                torsoArmor: 0, staggerResistance: 0.1, baseScore: 160,
                fleshHue: 2, ragHue: 2)
        case .crawler:
            return ZombieStats(
                maxHealth: 26, moveSpeed: 3.25, damage: 8, attackReach: 2.2,
                windup: 0.58, recovery: 0.9, scale: 0.9,
                headMultiplier: 3.2, torsoMultiplier: 1.0, limbMultiplier: 0.55,
                torsoArmor: 0, staggerResistance: 0.15, baseScore: 190,
                fleshHue: 3, ragHue: 3)
        case .brute:
            return ZombieStats(
                maxHealth: 150, moveSpeed: 1.40, damage: 22, attackReach: 2.6,
                windup: 1.25, recovery: 1.7, scale: 1.42,
                headMultiplier: 2.6, torsoMultiplier: 1.0, limbMultiplier: 0.5,
                torsoArmor: 0.82, staggerResistance: 0.85, baseScore: 400,
                fleshHue: 4, ragHue: 4)
        case .spitter:
            return ZombieStats(
                maxHealth: 42, moveSpeed: 1.25, damage: 11, attackReach: 17,
                windup: 1.55, recovery: 3.4, scale: 1.02,
                headMultiplier: 3.2, torsoMultiplier: 1.0, limbMultiplier: 0.6,
                torsoArmor: 0, staggerResistance: 0.2, baseScore: 280,
                fleshHue: 5, ragHue: 5, isRanged: true)
        case .warden:
            return ZombieStats(
                maxHealth: 1150, moveSpeed: 2.05, damage: 26, attackReach: 6.0,
                windup: 1.15, recovery: 1.9, scale: 2.35,
                headMultiplier: 6.0, torsoMultiplier: 0.05, limbMultiplier: 0.05,
                torsoArmor: 0.95, staggerResistance: 1.0, baseScore: 5000,
                fleshHue: 6, ragHue: 6, isBoss: true)
        }
    }

    /// Silhouette cue: bosses and brutes get a rim colour so they read instantly
    /// against a dark level even before the player can make out detail.
    var rimColor: NSColor? {
        switch self {
        case .brute: return NSColor(rgb: 0.62, 0.20, 0.10)
        case .spitter: return NSColor(rgb: 0.35, 0.62, 0.18)
        case .warden: return NSColor(rgb: 0.85, 0.14, 0.10)
        case .runner: return NSColor(rgb: 0.42, 0.30, 0.44)
        default: return nil
        }
    }
}

struct ZombieStats {
    var maxHealth: Float
    var moveSpeed: Float
    var damage: Float
    /// Metres per second. These are set against a *moving* player: the target
    /// can now walk at 4.1 m/s and sprint at 5.6, so anything slower than a walk
    /// is scenery unless the player chooses to engage it.
    /// Distance at which it begins an attack.
    var attackReach: Float
    /// Telegraph time before the strike lands — the player's window to react.
    var windup: Float
    /// Cooldown after a strike.
    var recovery: Float
    var scale: Float

    var headMultiplier: Float
    var torsoMultiplier: Float
    var limbMultiplier: Float
    /// 0..1 fraction of torso damage absorbed. Brutes force headshots.
    var torsoArmor: Float
    /// 0..1; higher means less flinching from hits.
    var staggerResistance: Float

    var baseScore: Int
    var fleshHue: Int
    var ragHue: Int
    var isRanged = false
    var isBoss = false
}

/// Where a bullet landed, which drives damage, effects and score.
enum HitZone {
    case head, torso, arm, leg

    var isLimb: Bool { self == .arm || self == .leg }

    var label: String {
        switch self {
        case .head: return "HEADSHOT"
        case .torso: return "HIT"
        case .arm: return "ARM"
        case .leg: return "LEG"
        }
    }
}
