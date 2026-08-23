import Foundation
import simd

/// The player's sidearm.
///
/// Tuned against the enemy table: 25 damage means a shambler takes two body
/// shots or one to the head, a runner the same, and a brute — whose torso
/// absorbs 82% — needs three headshots. That relationship is what makes "aim for
/// the head" a real decision rather than a slogan.
struct Weapon {
    var magazineSize = 8
    private(set) var ammoInMagazine = 8
    /// Reserve is deliberately unlimited: running dry permanently in a rail
    /// shooter is a dead end, not a challenge. Scarcity lives in the reload.
    var damage: Float = 25

    /// Seconds between shots when the trigger is held.
    var fireInterval: Float = 0.155
    var reloadDuration: Float = 1.25

    /// Cone half-angle in radians. Small but non-zero, so spamming at range is
    /// slightly worse than placing shots.
    var spread: Float = deg(0.35)

    private(set) var cooldown: Float = 0
    private(set) var isReloading = false
    private(set) var reloadElapsed: Float = 0
    /// Set on the frame a reload completes, for the HUD and audio.
    private(set) var justFinishedReload = false
    /// Set when the trigger was pulled with an empty magazine.
    private(set) var justDryFired = false

    var reloadProgress: Float {
        isReloading ? clamp01(reloadElapsed / reloadDuration) : 1
    }
    var isEmpty: Bool { ammoInMagazine <= 0 }

    mutating func update(dt: Float) {
        justFinishedReload = false
        justDryFired = false
        cooldown = max(0, cooldown - dt)
        if isReloading {
            reloadElapsed += dt
            if reloadElapsed >= reloadDuration {
                isReloading = false
                reloadElapsed = 0
                ammoInMagazine = magazineSize
                justFinishedReload = true
            }
        }
    }

    /// Returns true if a round was actually discharged.
    mutating func tryFire() -> Bool {
        guard !isReloading, cooldown <= 0 else { return false }
        guard ammoInMagazine > 0 else {
            // Dry fire has its own short cooldown so holding the trigger on an
            // empty magazine clicks at a sane rate instead of every frame.
            cooldown = 0.22
            justDryFired = true
            return false
        }
        ammoInMagazine -= 1
        cooldown = fireInterval
        return true
    }

    mutating func beginReload() {
        guard !isReloading, ammoInMagazine < magazineSize else { return }
        isReloading = true
        reloadElapsed = 0
    }

    /// Auto-reload when the magazine empties, after a short beat so the player
    /// registers that they ran out.
    mutating func autoReloadIfEmpty() {
        if isEmpty && !isReloading && cooldown <= 0 { beginReload() }
    }

    mutating func refill() {
        ammoInMagazine = magazineSize
        isReloading = false
        reloadElapsed = 0
    }

    /// Applies spread to an aim direction.
    func perturb(_ direction: SIMD3<Float>, rng: inout Rand) -> SIMD3<Float> {
        guard spread > 1e-5 else { return direction }
        let disc = rng.inUnitCircle() * tan(spread)
        // Build a basis around the aim direction and offset within its cone.
        let f = direction.normalizedSafe
        let ref: SIMD3<Float> = abs(f.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let r = simd_normalize(simd_cross(ref, f))
        let u = simd_cross(f, r)
        return simd_normalize(f + r * disc.x + u * disc.y)
    }
}
