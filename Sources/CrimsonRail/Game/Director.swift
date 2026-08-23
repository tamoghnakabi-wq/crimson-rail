import Foundation
import simd

/// Drives the level's pacing: when the rail moves, when it holds, and what
/// spawns while it does.
///
/// The one hard rule is that a run can never soft-lock. Every hold has a
/// failsafe timeout, and anything that wanders out of the world is written off
/// rather than waited on for ever.
final class Director {
    struct Command {
        /// Multiplier on the level's travel speed; 0 holds the camera.
        var speedScale: Float = 1
        var gaze: GazeTarget = .forward
    }

    /// Something the director wants spawned this frame.
    struct SpawnRequest {
        var def: SpawnDef
        var isAmbush: Bool
        /// The encounter that owns this spawn, or nil for an ambush. Used to
        /// scope the clear condition to the encounter that is actually running.
        var encounterID: String?
    }

    private let def: LevelDef
    private var encounterIndex = 0
    /// nil when travelling.
    private var activeEncounter: Int?
    private var encounterElapsed: Float = 0
    private var waveIndex = 0
    private var waveElapsed: Float = 0
    private var waveStarted = false
    /// Spawns queued from the current wave, with their remaining delay.
    private var pending: [(def: SpawnDef, remaining: Float)] = []
    private var firedAmbushes = Set<Int>()
    /// Enemies spawned by the active encounter that are still alive.
    private(set) var encounterThreatsRemaining = 0

    private(set) var bannerToShow: String?
    private(set) var finished = false

    /// Furthest rail distance the player may advance to right now, or nil for
    /// "no limit". A held encounter seals the far side of its arena.
    ///
    /// This is what carries the authored pacing over to free movement. Without
    /// it a player simply sprints past every encounter to the exit — the
    /// simulated player cleared level 1 in 45 s doing exactly that — and all five
    /// levels' scripting becomes scenery.
    private(set) var progressGate: Float?
    /// True while the gate is actually restricting the player.
    private(set) var isSealed = false

    init(def: LevelDef) {
        self.def = def
    }

    var isHolding: Bool { activeEncounter != nil }
    var currentEncounterID: String? {
        activeEncounter.map { def.encounters[$0].id }
    }
    var currentSurvivor: SurvivorDef? {
        activeEncounter.flatMap { def.encounters[$0].survivor }
    }

    /// Advances the schedule. `aliveFromEncounter` is how many enemies spawned by
    /// the active encounter are still standing.
    func update(dt: Float, railDistance: Float, aliveFromEncounter: Int,
                spawn: (SpawnRequest) -> Void) -> Command {
        bannerToShow = nil
        encounterThreatsRemaining = aliveFromEncounter
        progressGate = nil
        isSealed = false
        var cmd = Command()

        // ---- Ambushes: fire once, as the rail passes, without stopping --------
        for (i, amb) in def.ambushes.enumerated() where !firedAmbushes.contains(i) {
            // Trigger a little before the anchor so they are already moving when
            // they come into view.
            if railDistance >= amb.railDistance - 14 {
                firedAmbushes.insert(i)
                spawn(SpawnRequest(def: amb, isAmbush: true, encounterID: nil))
            }
        }

        // ---- Encounter start ---------------------------------------------------
        if activeEncounter == nil, encounterIndex < def.encounters.count {
            let next = def.encounters[encounterIndex]
            if railDistance >= next.triggerDistance {
                activeEncounter = encounterIndex
                encounterElapsed = 0
                waveIndex = 0
                waveElapsed = 0
                waveStarted = false
                pending.removeAll()
                bannerToShow = next.banner
            }
        }

        // ---- Active encounter ---------------------------------------------------
        if let idx = activeEncounter {
            let enc = def.encounters[idx]
            encounterElapsed += dt
            cmd.gaze = enc.gaze
            cmd.speedScale = enc.holdPosition ? 0 : 0.35

            if enc.holdPosition {
                // Seal a little past the furthest spawn, so every enemy in the
                // encounter is reachable and the player has room to circle,
                // retreat and reposition inside the arena.
                let furthest = enc.waves.flatMap { $0.spawns }.map { $0.railDistance }.max()
                    ?? (enc.triggerDistance + 18)
                progressGate = max(furthest + 8, enc.triggerDistance + 20)
                isSealed = true
            }

            // Release queued spawns as their individual delays expire.
            var k = 0
            while k < pending.count {
                pending[k].remaining -= dt
                if pending[k].remaining <= 0 {
                    spawn(SpawnRequest(def: pending[k].def, isAmbush: false, encounterID: enc.id))
                    pending.remove(at: k)
                } else {
                    k += 1
                }
            }

            if waveIndex < enc.waves.count {
                let wave = enc.waves[waveIndex]
                waveElapsed += dt
                let gateOpen: Bool
                if wave.afterPreviousCleared {
                    // First wave has nothing to wait for; later ones wait for a wipe.
                    gateOpen = (waveIndex == 0) || (aliveFromEncounter == 0 && pending.isEmpty)
                } else {
                    gateOpen = true
                }
                if !waveStarted && gateOpen && waveElapsed >= wave.startDelay {
                    for s in wave.spawns {
                        pending.append((s, max(s.delay, 0)))
                    }
                    waveStarted = true
                }
                if waveStarted && pending.isEmpty {
                    // Wave fully released; move on once its enemies are handled by
                    // the next wave's gate.
                    waveIndex += 1
                    waveElapsed = 0
                    waveStarted = false
                }
            } else if aliveFromEncounter == 0 && pending.isEmpty {
                // Everything spawned and everything dead: release the rail.
                activeEncounter = nil
                encounterIndex += 1
                cmd.speedScale = 1
                cmd.gaze = .forward
            }

            // Failsafe. An enemy stuck on geometry, or one that fell out of the
            // world, must never hold the player at a hold point indefinitely.
            // Anything still alive keeps hunting the player — it just stops
            // gating progress, because its tag no longer names a live encounter.
            if encounterElapsed > enc.failsafeTimeout {
                activeEncounter = nil
                encounterIndex += 1
                pending.removeAll()
                cmd.speedScale = 1
                cmd.gaze = .forward
            }
        }

        if encounterIndex >= def.encounters.count && activeEncounter == nil {
            finished = true
        }
        return cmd
    }

    /// Progress through the level's encounters, for the HUD.
    var encounterProgress: Float {
        guard !def.encounters.isEmpty else { return 1 }
        return Float(encounterIndex) / Float(def.encounters.count)
    }
}
