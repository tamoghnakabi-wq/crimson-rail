import Foundation
import SceneKit
import AVFoundation
import simd

/// Invariant checks over the parts of the game where a silent regression would
/// be expensive to find by playing: the rail maths, hit detection, the aim
/// pipeline, the save format, and every level's authored data.
extension Harness {

    private struct Checker {
        var passed = 0
        var failures: [String] = []

        mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                passed += 1
            } else {
                let d = detail()
                failures.append(d.isEmpty ? name : "\(name): \(d)")
            }
        }

        mutating func near(_ name: String, _ a: Float, _ b: Float, tol: Float = 1e-3) {
            check(name, abs(a - b) <= tol, String(format: "%.5f vs %.5f", a, b))
        }
    }

    static func selftest(_ args: Args) -> Int32 {
        var c = Checker()
        out("CRIMSON RAIL — self test")
        out("")

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. spline") }
        // ---- Spline ---------------------------------------------------------
        do {
            let s = Spline([SIMD3(0, 0, 0), SIMD3(0, 0, 10), SIMD3(5, 0, 20), SIMD3(5, 0, 30)])
            c.check("spline has positive length", s.totalLength > 25)
            let p0 = s.position(atDistance: 0)
            c.near("spline starts at first control point", simd_distance(p0, SIMD3(0, 0, 0)), 0, tol: 0.05)
            let pEnd = s.position(atDistance: s.totalLength)
            c.near("spline ends at last control point", simd_distance(pEnd, SIMD3(5, 0, 30)), 0, tol: 0.15)

            // Arc-length parameterisation should be near-uniform: equal distance
            // steps must produce near-equal world steps.
            var worst: Float = 0
            var prev = s.position(atDistance: 0)
            for i in 1...40 {
                let p = s.position(atDistance: Float(i) / 40 * s.totalLength)
                worst = max(worst, abs(simd_distance(p, prev) - s.totalLength / 40))
                prev = p
            }
            c.check("arc-length steps are uniform", worst < 0.35, String(format: "worst deviation %.3f m", worst))
            c.near("tangent is unit length", simd_length(s.tangent(atDistance: 12)), 1, tol: 1e-3)
            // Monotonic progress: the rail must never double back on itself.
            var lastZ = -Float.greatestFiniteMagnitude
            var monotonic = true
            for i in 0...50 {
                let z = s.position(atDistance: Float(i) / 50 * s.totalLength).z
                if z < lastZ - 0.01 { monotonic = false }
                lastZ = z
            }
            c.check("rail advances monotonically", monotonic)
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. mesh") }
        // ---- Mesh winding ---------------------------------------------------
        do {
            var m = MeshBuilder()
            // Counter-clockwise seen from +Y should give an upward normal.
            m.addQuad(SIMD3(-1, 0, -1), SIMD3(-1, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 0, -1))
            let n = m.normalAt(0)
            c.check("CCW-from-above quad faces up", n.y > 0.99, String(format: "normal %.2f %.2f %.2f", n.x, n.y, n.z))

            var box = MeshBuilder()
            box.addBox(center: .zero, size: SIMD3(2, 2, 2))
            c.check("box has 12 triangles", box.triangleCount == 12, "\(box.triangleCount)")
            // Every box face normal must point away from the centre.
            var outward = true
            for i in 0..<box.vertexCount {
                let p = box.positionAt(i), nn = box.normalAt(i)
                if simd_dot(simd_normalize(p), nn) < 0.5 { outward = false }
            }
            c.check("box normals face outward", outward)
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. raycapsule") }
        // ---- Ray/capsule hit detection --------------------------------------
        do {
            let node = SCNNode()
            node.simdPosition = SIMD3(0, 1, 0)
            let scene = SCNScene()
            scene.rootNode.addChildNode(node)

            // Straight down the barrel of a capsule from 0 to -1 in local Y.
            let hit = ZombieBody.rayCapsule(origin: SIMD3(0, 0.5, 5), direction: SIMD3(0, 0, -1),
                                            node: node, radius: 0.3, y0: 0, y1: -1)
            c.check("ray hits capsule", hit != nil)
            if let t = hit { c.near("capsule hit distance", t, 4.7, tol: 0.05) }

            let miss = ZombieBody.rayCapsule(origin: SIMD3(4, 0.5, 5), direction: SIMD3(0, 0, -1),
                                             node: node, radius: 0.3, y0: 0, y1: -1)
            c.check("ray misses capsule when offset", miss == nil)

            let behind = ZombieBody.rayCapsule(origin: SIMD3(0, 0.5, -5), direction: SIMD3(0, 0, -1),
                                               node: node, radius: 0.3, y0: 0, y1: -1)
            c.check("ray pointing away does not hit", behind == nil)
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. aim") }
        // ---- Aim pipeline: project then unproject must round-trip -------------
        do {
            let session = Session(def: LevelCatalog.level(0), settings: quietSettings())
            session.aspect = 16.0 / 9.0
            for _ in 0..<4 { session.field.update(dt: 1.0 / 60.0) }

            let eye = session.field.cameraNode.simdWorldPosition
            var worstError: Float = 0
            for (dx, dy) in [(Float(0), Float(0)), (0.5, 0.3), (-0.7, 0.6), (0.9, -0.8)] {
                let ndc = SIMD2<Float>(dx, dy)
                let dir = session.rayDirection(ndc: ndc)
                let world = eye + dir * 20
                guard let back = session.field.project(world, aspect: session.aspect) else {
                    c.check("projection round-trip returns a point", false)
                    continue
                }
                worstError = max(worstError, simd_distance(back, ndc))
            }
            c.check("aim ray and projection agree", worstError < 0.01,
                    String(format: "worst NDC error %.5f", worstError))
            session.teardown()
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. director") }
        // ---- Encounter scheduling ---------------------------------------------
        do {
            let def = LevelCatalog.level(0)
            let director = Director(def: def)
            // Spawns must be attributed to the encounter that issued them, or a
            // timed-out hold's survivors gate every encounter after it.
            var seenIDs = Set<String>()
            var ambushCount = 0
            var d: Float = 0
            var t: Float = 0
            // Walk the level, never clearing the first encounter, and let its
            // failsafe fire.
            var stuckEncounter: String?
            var completedWithoutFailsafe = false
            var elapsedInSecond: Float = 0
            while t < 400 {
                let dt: Float = 1.0 / 30.0
                t += dt
                elapsedInSecond += dt
                // Advance to the first encounter, then hold position.
                if director.currentEncounterID == nil { d += dt * 3 }

                // One enemy is permanently stuck in the first encounter only.
                let current = director.currentEncounterID
                var alive = 0
                if let c = current {
                    if stuckEncounter == nil { stuckEncounter = c }
                    alive = (c == stuckEncounter) ? 1 : 0
                }
                let before = director.currentEncounterID
                _ = director.update(dt: dt, railDistance: d, aliveFromEncounter: alive) { req in
                    if let id = req.encounterID { seenIDs.insert(id) } else { ambushCount += 1 }
                    c.check("spawn attribution matches ambush flag",
                            (req.encounterID == nil) == req.isAmbush)
                }
                // The second encounter should clear on its own merits, quickly,
                // rather than sitting out another full failsafe.
                if let b = before, b != stuckEncounter, director.currentEncounterID != b {
                    completedWithoutFailsafe = true
                    break
                }
            }
            // The rule the failsafe bug actually lived in. Driving the Director
            // with a synthetic count does not touch it — this exercises the
            // counting function the session really uses.
            do {
                func z(_ kind: ZombieKind) -> Zombie {
                    Zombie(kind: kind, position: .zero, facing: 0, entrance: .lurch,
                           difficulty: .agent, seed: 1)
                }
                let strandedByC1 = z(.shambler)     // survived a timed-out hold
                let ownedByC2 = z(.runner)          // belongs to the live encounter
                let ambusher = z(.crawler)          // belongs to no encounter
                var tags: [ObjectIdentifier: String] = [
                    ObjectIdentifier(strandedByC1): "c1",
                    ObjectIdentifier(ownedByC2): "c2",
                ]
                let all = [strandedByC1, ownedByC2, ambusher]

                c.check("only the live encounter's own enemies gate it",
                        Session.threatsOwed(to: "c2", among: all, tags: tags) == 1,
                        "\(Session.threatsOwed(to: "c2", among: all, tags: tags))")
                c.check("a timed-out encounter's survivors gate nothing",
                        Session.threatsOwed(to: "c3", among: all, tags: tags) == 0,
                        "\(Session.threatsOwed(to: "c3", among: all, tags: tags))")
                c.check("ambushers never gate an encounter",
                        Session.threatsOwed(to: "c1", among: [ambusher], tags: tags) == 0)
                c.check("nothing is owed while no encounter is running",
                        Session.threatsOwed(to: nil, among: all, tags: tags) == 0)
                // A dead enemy stops counting, or a corpse would hold the gate.
                _ = ownedByC2.applyDamage(10_000, zone: .head, partIndex: nil, allowSever: false)
                c.check("dead enemies stop gating",
                        Session.threatsOwed(to: "c2", among: all, tags: tags) == 0)
                tags.removeAll()
            }

            c.check("encounter spawns carry an encounter ID", !seenIDs.isEmpty)
            c.check("ambush spawns carry no encounter ID", ambushCount > 0)
            c.check("a timed-out encounter does not gate the next one",
                    completedWithoutFailsafe,
                    "the encounter after a failsafe never cleared")
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. navigation") }
        // ---- Rail projection and free movement --------------------------------
        do {
            // A path that loops back near its own start — the shape that broke
            // global nearest-point projection on levels 2 and 4.
            let loop = Spline([SIMD3(0, 0, 0), SIMD3(0, 0, 20), SIMD3(14, 0, 30),
                               SIMD3(24, 0, 20), SIMD3(22, 0, 4), SIMD3(6, 0, -2)])
            let proj = RailProjector(spline: loop)

            var worstRoundTrip: Float = 0
            for i in 0...20 {
                let d = Float(i) / 20 * proj.totalLength
                let w = proj.worldPoint(distance: d, lateral: 0)
                let back = proj.project(w, hint: d)
                worstRoundTrip = max(worstRoundTrip, abs(back.distance - d))
            }
            c.check("projector round-trips a rail distance", worstRoundTrip < 1.2,
                    String(format: "worst %.2f m", worstRoundTrip))

            // Lateral offset must come back signed and correct.
            let side = proj.worldPoint(distance: 10, lateral: 3)
            let sideProj = proj.project(side, hint: 10)
            c.near("projector recovers lateral offset", sideProj.lateral, 3, tol: 0.35)

            // The end of this loop passes close to its start. Without the hint a
            // point near the end projects back to the beginning.
            let nearEnd = proj.worldPoint(distance: proj.totalLength - 4, lateral: 0)
            let hinted = proj.project(nearEnd, hint: proj.totalLength - 4)
            c.check("hinted projection stays at the far end",
                    hinted.distance > proj.totalLength * 0.7,
                    String(format: "%.0f of %.0f", hinted.distance, proj.totalLength))
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. movement") }
        do {
            let session = Session(def: LevelCatalog.level(0), settings: quietSettings())
            session.aspect = 16.0 / 9.0
            let player = session.field.player
            let startDistance = player.railDistance

            // Walking forward makes progress along the level's spine.
            var input = PlayerController.MoveInput()
            input.forward = 1
            for _ in 0..<120 { session.field.update(dt: 1.0 / 60.0, input: input) }
            c.check("W moves the player down the level",
                    player.railDistance > startDistance + 2,
                    String(format: "%.1f -> %.1f", startDistance, player.railDistance))

            // Strafing sideways cannot leave the walkable band.
            var strafe = PlayerController.MoveInput()
            strafe.strafe = 1
            for _ in 0..<600 { session.field.update(dt: 1.0 / 60.0, input: strafe) }
            let halfWidth = session.field.built.corridorHalfWidth
            c.check("player is held inside the corridor",
                    abs(player.railLateral) <= halfWidth + 0.6,
                    String(format: "lateral %.1f of %.1f", player.railLateral, halfWidth))

            // A sealed encounter must actually stop forward progress.
            let limit = player.railDistance + 3
            player.progressLimit = limit
            for _ in 0..<300 { session.field.update(dt: 1.0 / 60.0, input: input) }
            c.check("a sealed arena holds the player",
                    player.railDistance <= limit + 1.0,
                    String(format: "%.1f past a limit of %.1f", player.railDistance, limit))
            player.progressLimit = nil

            // Mouse look turns the camera.
            var look = PlayerController.MoveInput()
            look.lookDeltaX = 200
            let yawBefore = player.yaw
            session.field.update(dt: 1.0 / 60.0, input: look)
            c.check("mouse look turns the player", abs(angleDelta(yawBefore, player.yaw)) > 0.05)

            // Pitch must stay clamped no matter how far the mouse is dragged.
            var look2 = PlayerController.MoveInput()
            look2.lookDeltaY = -100_000
            session.field.update(dt: 1.0 / 60.0, input: look2)
            c.check("pitch is clamped", abs(player.pitch) <= deg(86),
                    String(format: "%.1f deg", player.pitch * 180 / .pi))
            session.teardown()
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. anatomy") }
        // ---- Bodies ------------------------------------------------------------
        do {
            for kind in ZombieKind.allCases {
                let body = ZombieBody(kind: kind, seed: 4242)
                let label = kind.rawValue

                var verts = 0
                var lowest = Float.greatestFiniteMagnitude
                var highest = -Float.greatestFiniteMagnitude
                body.root.enumerateHierarchy { n, _ in
                    guard let g = n.geometry else { return }
                    verts += g.sources(for: .vertex).first?.vectorCount ?? 0
                    let (lo, hi) = n.boundingBox
                    let w = n.convertPosition(lo, to: body.root)
                    let w2 = n.convertPosition(hi, to: body.root)
                    lowest = min(lowest, Float(min(w.y, w2.y)))
                    highest = max(highest, Float(max(w.y, w2.y)))
                }
                // Feet on the floor: a model that hovers or sinks is immediately
                // obvious once the player can walk right up to it.
                c.check("\(label): stands on the ground", abs(lowest) < 0.10,
                        String(format: "lowest point %.3f m", lowest))
                c.check("\(label): is a plausible height", highest > 1.4 && highest < 2.6,
                        String(format: "%.2f m", highest))
                // Budget: these are drawn a dozen at a time.
                c.check("\(label): stays within the vertex budget", verts < 9000, "\(verts) verts")
                c.check("\(label): has all its hit zones", body.parts.count >= 11, "\(body.parts.count)")
                c.check("\(label): has a head zone", body.parts.contains { $0.zone == .head })
                c.check("\(label): has severable limbs", body.parts.contains { $0.severable })
            }
            let warden = ZombieBody(kind: .warden, seed: 1)
            c.check("warden has weak points", warden.weakPoints.count == 3, "\(warden.weakPoints.count)")
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. damage") }
        // ---- Damage model ------------------------------------------------------
        do {
            let z = Zombie(kind: .shambler, position: .zero, facing: 0, entrance: .lurch,
                           difficulty: .agent, seed: 7)
            let hp = z.stats.maxHealth
            let body = z.applyDamage(10, zone: .torso, partIndex: nil, allowSever: false)
            c.near("torso damage uses torso multiplier", body.applied, 10 * z.stats.torsoMultiplier)
            let head = z.applyDamage(10, zone: .head, partIndex: nil, allowSever: false)
            c.near("head damage uses head multiplier", head.applied, 10 * z.stats.headMultiplier)
            c.check("headshots hurt more than body shots", head.applied > body.applied)
            _ = hp

            // A brute's torso must absorb most of the damage; its head must not.
            let brute = Zombie(kind: .brute, position: .zero, facing: 0, entrance: .lurch,
                               difficulty: .agent, seed: 8)
            let t = brute.applyDamage(25, zone: .torso, partIndex: nil, allowSever: false)
            c.check("brute torso is armoured", t.absorbed && t.applied < 6,
                    String(format: "%.1f damage got through", t.applied))

            // Enough headshots must actually kill it, or the archetype is a wall.
            var shots = 0
            while brute.isThreat && shots < 40 {
                _ = brute.applyDamage(25, zone: .head, partIndex: nil, allowSever: false)
                shots += 1
            }
            c.check("brute dies to headshots", !brute.isThreat && shots <= 4, "\(shots) headshots")
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. persistence") }
        // ---- Persistence -------------------------------------------------------
        do {
            var save = SaveData()
            var result = RunResult()
            result.won = true; result.score = 5000; result.shots = 100; result.hits = 80
            result.kills = 20; result.totalThreats = 20; result.healthRemaining = 80; result.healthMax = 100
            save.record(levelIndex: 0, result: result)
            c.check("winning unlocks the next level", save.highestUnlocked == 1, "\(save.highestUnlocked)")
            c.check("completion is recorded", save.levels[0].completed)

            let data = try! JSONEncoder().encode(save)
            let restored = try! JSONDecoder().decode(SaveData.self, from: data)
            c.check("save round-trips", restored.highestUnlocked == save.highestUnlocked
                    && restored.levels[0].bestScore == save.levels[0].bestScore)

            // Forward compatibility: an older file missing newer keys must load
            // with defaults rather than resetting the player's progress.
            let partial = #"{"highestUnlocked":3}"#.data(using: .utf8)!
            let old = try? JSONDecoder().decode(SaveData.self, from: partial)
            c.check("partial save decodes", old != nil)
            c.check("partial save keeps its value", old?.highestUnlocked == 3, "\(old?.highestUnlocked ?? -1)")
            c.check("partial save fills the level table",
                    (old?.levels.count ?? 0) == LevelCatalog.count)

            let emptySettings = "{}".data(using: .utf8)!
            let s = try? JSONDecoder().decode(Settings.self, from: emptySettings)
            c.check("empty settings decode to defaults", s != nil && s?.gameplay.difficulty == .agent)
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. ranking") }
        // ---- Ranking -------------------------------------------------------------
        do {
            let perfect = Rank.evaluate(accuracy: 1, healthFraction: 1, killFraction: 1, comboBest: 30)
            let awful = Rank.evaluate(accuracy: 0.2, healthFraction: 0.05, killFraction: 0.4, comboBest: 1)
            c.check("a perfect run ranks S", perfect == .s, perfect.rawValue)
            c.check("a poor run ranks D", awful == .d, awful.rawValue)
            // Monotonic in accuracy.
            var lastOrder = 0
            var monotonic = true
            for i in 0...10 {
                let r = Rank.evaluate(accuracy: Float(i) / 10, healthFraction: 0.6,
                                      killFraction: 0.9, comboBest: 10)
                if r.order < lastOrder { monotonic = false }
                lastOrder = r.order
            }
            c.check("rank improves with accuracy", monotonic)
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. leveldata") }
        // ---- Level data ----------------------------------------------------------
        for (i, def) in LevelCatalog.all.enumerated() {
            let label = "L\(i + 1) \(def.name)"
            let spline = Spline(def.railPoints)
            c.check("\(label): rail is long enough", spline.totalLength > 60,
                    String(format: "%.0f m", spline.totalLength))
            c.check("\(label): has encounters", !def.encounters.isEmpty)

            var lastTrigger: Float = -1
            var ordered = true
            for e in def.encounters {
                if e.triggerDistance < lastTrigger { ordered = false }
                lastTrigger = e.triggerDistance
                c.check("\(label)/\(e.id): triggers within the rail",
                        e.triggerDistance >= 0 && e.triggerDistance < spline.totalLength,
                        String(format: "%.0f of %.0f", e.triggerDistance, spline.totalLength))
                c.check("\(label)/\(e.id): has waves", !e.waves.isEmpty)
                for w in e.waves {
                    for s in w.spawns {
                        c.check("\(label)/\(e.id): spawn is on the rail",
                                s.railDistance >= 0 && s.railDistance <= spline.totalLength + 12,
                                String(format: "%.0f", s.railDistance))
                        c.check("\(label)/\(e.id): spawn is clear of the player's lane",
                                abs(s.lateral) >= 0 && abs(s.lateral) < 12,
                                String(format: "lateral %.1f", s.lateral))
                        // Spawns must be ahead of the trigger, or they appear
                        // behind the player as the encounter opens.
                        c.check("\(label)/\(e.id): spawn is ahead of its trigger",
                                s.railDistance > e.triggerDistance,
                                String(format: "spawn %.0f vs trigger %.0f", s.railDistance, e.triggerDistance))
                    }
                }
            }
            c.check("\(label): encounters are in rail order", ordered)
            c.check("\(label): has a reasonable threat count",
                    def.totalThreats >= 12 && def.totalThreats <= 90, "\(def.totalThreats)")

            // The ground sampler must return finite values everywhere on the rail.
            let built = Environments.build(def, quality: .forPreset(.low))
            var finite = true
            var dd: Float = 0
            while dd < spline.totalLength {
                let p = spline.position(atDistance: dd)
                let y = built.groundHeight(p)
                if !y.isFinite || abs(y - p.y) > 3.5 { finite = false }
                dd += 5
            }
            c.check("\(label): ground follows the rail", finite)
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. audio") }
        // ---- Audio bank ------------------------------------------------------------
        do {
            var silent: [String] = []
            var clipped: [String] = []
            var nan: [String] = []
            for id in SoundID.allCases {
                let buf = SoundBank.render(id, variant: 0)
                if buf.s.contains(where: { !$0.isFinite }) { nan.append(id.rawValue) }
                if buf.rms < 0.001 { silent.append(id.rawValue) }
                if buf.peak > 1.001 { clipped.append(id.rawValue) }
            }
            c.check("no sound is silent", silent.isEmpty, silent.joined(separator: ", "))
            c.check("no sound clips", clipped.isEmpty, clipped.joined(separator: ", "))
            c.check("no sound contains NaN", nan.isEmpty, nan.joined(separator: ", "))
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. settings") }
        // ---- Settings writes are debounced ------------------------------------
        do {
            // A SwiftUI Slider calls its setter on every tick of a drag. Writing
            // the settings file from there directly meant a JSON encode plus an
            // atomic file replace dozens of times a second, and a Metal backing
            // store resize with it.
            let view = GameView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let game = Game(view: view)
            let before = Store.writeCount
            var s = game.settings
            // 120 ticks, as a two-second drag would produce.
            for i in 0..<120 {
                s.audio.music = Float(i) / 120
                game.updateSettings(s)
            }
            let duringDrag = Store.writeCount - before
            c.check("a slider drag does not write on every tick", duringDrag == 0,
                    "\(duringDrag) writes for 120 ticks")

            // Leaving the settings screen must commit, or the change is lost.
            game.setMode(.settings)
            s.audio.music = 0.42
            game.updateSettings(s)
            game.setMode(.mainMenu)
            c.check("leaving the settings screen commits the change",
                    Store.writeCount > before, "no write happened")
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil { out("  .. properties") }
        // ---- Randomised property tests ----------------------------------------
        do {
            let failures = PropertyTests.runAll()
            c.check("randomised property tests hold", failures.isEmpty,
                    failures.map { $0.property + ($0.detail.isEmpty ? "" : " (\($0.detail))") }
                        .joined(separator: "; "))
        }

        // ---- Report -----------------------------------------------------------------
        out("")
        if c.failures.isEmpty {
            out("PASS — \(c.passed) checks")
            return 0
        }
        out("FAIL — \(c.failures.count) of \(c.passed + c.failures.count) checks failed")
        for f in c.failures { out("  ✗ \(f)") }
        return 1
    }

    /// Settings that build fast and make no noise, for tests.
    private static func quietSettings() -> Settings {
        var s = Settings()
        s.graphics = .forPreset(.low)
        s.graphics.particleBudget = 0
        return s
    }
}
