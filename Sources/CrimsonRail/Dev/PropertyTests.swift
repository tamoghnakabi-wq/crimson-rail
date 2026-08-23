import Foundation
import simd

/// Randomised property tests over the pure game logic.
///
/// The soak test exercises a whole session but only visits the states a plausible
/// player reaches. These hammer the small stateful pieces — the weapon, the save
/// file, the scoring — with thousands of arbitrary inputs, which is where
/// off-by-ones and unreachable-looking states actually live.
enum PropertyTests {

    struct Failure {
        var property: String
        var detail: String
    }

    static func runAll(iterations: Int = 4000) -> [Failure] {
        var failures: [Failure] = []
        failures += weaponStateMachine(iterations: iterations)
        failures += saveProgression(iterations: iterations)
        failures += rankAndResults(iterations: iterations)
        return failures
    }

    // MARK: Weapon

    /// The weapon must never reach an impossible state, whatever order the
    /// player mashes fire and reload in.
    private static func weaponStateMachine(iterations: Int) -> [Failure] {
        var failures: [Failure] = []
        var rng = Rand(seed: 0xBEEF)
        var w = Weapon()
        var firedWhileReloading = false
        var ammoWentOutOfRange = false
        var reloadNeverFinished = false
        var stuckReloadFrames = 0

        for _ in 0..<iterations {
            let dt = rng.float(0.001, 0.12)   // includes the frame-time clamp
            w.update(dt: dt)
            if rng.chance(0.4) {
                let ammoBefore = w.ammoInMagazine
                // Sampled immediately before the call: a reload that *completed*
                // inside `update` is no longer in progress, and firing then is
                // correct. Reading the flag before the update instead reports a
                // legitimate shot as a violation.
                let reloadingNow = w.isReloading
                let fired = w.tryFire()
                if fired && reloadingNow { firedWhileReloading = true }
                if fired && w.ammoInMagazine != ammoBefore - 1 { ammoWentOutOfRange = true }
            }
            if rng.chance(0.1) { w.beginReload() }
            if rng.chance(0.5) { w.autoReloadIfEmpty() }

            if w.ammoInMagazine < 0 || w.ammoInMagazine > w.magazineSize { ammoWentOutOfRange = true }
            if w.reloadProgress < 0 || w.reloadProgress > 1.0001 { ammoWentOutOfRange = true }

            // A reload must always terminate; a stuck one leaves the player
            // permanently unable to shoot.
            stuckReloadFrames = w.isReloading ? stuckReloadFrames + 1 : 0
            if stuckReloadFrames > 4000 { reloadNeverFinished = true }
        }

        if firedWhileReloading { failures.append(.init(property: "weapon fires while reloading", detail: "")) }
        if ammoWentOutOfRange { failures.append(.init(property: "weapon ammo/progress out of range", detail: "")) }
        if reloadNeverFinished { failures.append(.init(property: "weapon reload never completes", detail: "")) }

        // An empty magazine must always recover on its own, or a player who
        // never presses R is softlocked.
        var w2 = Weapon()
        while !w2.isEmpty { _ = w2.tryFire(); w2.update(dt: 0.2) }
        var recovered = false
        for _ in 0..<400 {
            w2.update(dt: 1.0 / 60.0)
            w2.autoReloadIfEmpty()
            if w2.ammoInMagazine == w2.magazineSize { recovered = true; break }
        }
        if !recovered {
            failures.append(.init(property: "an empty magazine never auto-reloads", detail: ""))
        }
        return failures
    }

    // MARK: Save data

    /// Progression must be monotonic and never point at a level that does not
    /// exist, whatever sequence of wins and losses is recorded.
    private static func saveProgression(iterations: Int) -> [Failure] {
        var failures: [Failure] = []
        var rng = Rand(seed: 0x5A7E)
        var save = SaveData()
        var lastUnlocked = save.highestUnlocked
        var wentBackwards = false
        var outOfRange = false
        var bestScoreRegressed = false
        var skippedALevel = false
        var bestScores = [Int](repeating: 0, count: LevelCatalog.count)

        for _ in 0..<iterations {
            // Only levels the player can actually reach may be played.
            let idx = rng.int(0, save.highestUnlocked)
            var r = RunResult()
            r.won = rng.chance(0.45)
            r.score = rng.int(0, 90_000)
            r.shots = rng.int(0, 600)
            r.hits = rng.int(0, r.shots)
            r.kills = rng.int(0, 60)
            r.totalThreats = max(r.kills, rng.int(1, 60))
            r.healthMax = 115
            r.healthRemaining = rng.float(0, 115)
            r.duration = rng.float(20, 400)

            let before = save.highestUnlocked
            save.record(levelIndex: idx, result: r)

            if save.highestUnlocked < before { wentBackwards = true }
            if save.highestUnlocked > before + 1 { skippedALevel = true }
            if save.highestUnlocked < 0 || save.highestUnlocked >= LevelCatalog.count { outOfRange = true }
            // A best score must never go down.
            if save.levels[idx].bestScore < bestScores[idx] { bestScoreRegressed = true }
            bestScores[idx] = save.levels[idx].bestScore
            lastUnlocked = save.highestUnlocked
        }
        _ = lastUnlocked

        if wentBackwards { failures.append(.init(property: "progression went backwards", detail: "")) }
        if skippedALevel { failures.append(.init(property: "progression skipped a level", detail: "")) }
        if outOfRange { failures.append(.init(property: "highestUnlocked left the catalog", detail: "")) }
        if bestScoreRegressed { failures.append(.init(property: "a best score regressed", detail: "")) }

        // Beating the final level must mark the campaign cleared and must not
        // try to unlock a sixth level.
        var endSave = SaveData()
        endSave.highestUnlocked = LevelCatalog.count - 1
        var win = RunResult()
        win.won = true; win.score = 1000; win.shots = 10; win.hits = 10
        win.totalThreats = 10; win.kills = 10; win.healthMax = 100; win.healthRemaining = 100
        endSave.record(levelIndex: LevelCatalog.count - 1, result: win)
        if !endSave.campaignCleared {
            failures.append(.init(property: "beating the last level does not clear the campaign", detail: ""))
        }
        if endSave.highestUnlocked != LevelCatalog.count - 1 {
            failures.append(.init(property: "beating the last level unlocked a level that does not exist",
                                  detail: "\(endSave.highestUnlocked)"))
        }

        // A round trip through JSON must preserve everything that matters.
        let data = try? JSONEncoder().encode(save)
        let restored = data.flatMap { try? JSONDecoder().decode(SaveData.self, from: $0) }
        if restored?.highestUnlocked != save.highestUnlocked
            || restored?.totalKills != save.totalKills
            || restored?.levels.count != save.levels.count {
            failures.append(.init(property: "save does not survive a JSON round trip", detail: ""))
        }
        return failures
    }

    // MARK: Ranking and results

    private static func rankAndResults(iterations: Int) -> [Failure] {
        var failures: [Failure] = []
        var rng = Rand(seed: 0x2A4C)
        var accuracyOutOfRange = false
        var nonFinite = false

        for _ in 0..<iterations {
            var r = RunResult()
            r.shots = rng.int(0, 900)
            r.hits = rng.int(0, max(r.shots, 0))
            r.totalThreats = rng.int(0, 90)
            r.kills = rng.int(0, 90)
            r.healthMax = rng.chance(0.05) ? 0 : rng.float(1, 200)   // include a zero max
            r.healthRemaining = rng.float(0, 200)
            r.bestCombo = rng.int(0, 200)

            // Accuracy and the fractions feed the rank and the results screen;
            // any of them going out of range or non-finite shows up as nonsense
            // on the card the player actually reads.
            if !r.accuracy.isFinite || !r.healthFraction.isFinite || !r.killFraction.isFinite {
                nonFinite = true
            }
            if r.accuracy < 0 || r.accuracy > 1.0001 { accuracyOutOfRange = true }
            if r.healthFraction < 0 || r.healthFraction > 1.0001 { accuracyOutOfRange = true }
            _ = r.rank
        }

        if nonFinite { failures.append(.init(property: "run result produced a non-finite value", detail: "")) }
        if accuracyOutOfRange { failures.append(.init(property: "run result fraction out of range", detail: "")) }

        // Rank must not improve when every input gets worse.
        var previous = 6
        for step in stride(from: 10, through: 0, by: -1) {
            let t = Float(step) / 10
            let r = Rank.evaluate(accuracy: t, healthFraction: t, killFraction: t, comboBest: Int(t * 30))
            if r.order > previous {
                failures.append(.init(property: "rank improved as performance worsened", detail: "at \(t)"))
                break
            }
            previous = r.order
        }
        return failures
    }
}
