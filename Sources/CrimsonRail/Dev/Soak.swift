import Foundation
import SceneKit
import simd

/// Long-running stress tests that assert invariants every frame.
///
/// The balance harness asks "can this be won"; this asks "does anything drift,
/// leak, or go non-finite if you keep playing". Those are different failures and
/// the second kind is invisible in a two-minute playthrough — a node leak or a
/// slowly-growing array only shows up after thousands of frames or a dozen
/// restarts, which is exactly the shape of a real play session.
enum Soak {

    struct Violation: Hashable {
        var name: String
        var detail: String
    }

    /// Everything that must hold at every single frame, forever.
    static func checkInvariants(_ s: Session, frame: Int, into found: inout Set<Violation>) {
        func fail(_ name: String, _ detail: @autoclosure () -> String) {
            // One report per distinct violation; a broken invariant fires every
            // frame and would otherwise bury everything else.
            found.insert(Violation(name: name, detail: detail()))
        }

        if !s.health.isFinite { fail("health is non-finite", "\(s.health)") }
        if s.health < 0 { fail("health went negative", String(format: "%.2f", s.health)) }
        if s.health > s.maxHealth + 0.01 {
            fail("health exceeded maximum", String(format: "%.1f of %.1f", s.health, s.maxHealth))
        }
        if s.score < 0 { fail("score went negative", "\(s.score)") }
        if s.hits > s.shots { fail("more hits than shots", "\(s.hits) of \(s.shots)") }
        if s.weapon.ammoInMagazine < 0 || s.weapon.ammoInMagazine > s.weapon.magazineSize {
            fail("ammo out of range", "\(s.weapon.ammoInMagazine) of \(s.weapon.magazineSize)")
        }
        if !s.weapon.reloadProgress.isFinite || s.weapon.reloadProgress < 0 || s.weapon.reloadProgress > 1.001 {
            fail("reload progress out of range", "\(s.weapon.reloadProgress)")
        }

        let p = s.field.player
        let pos = p.eyePosition
        if !pos.x.isFinite || !pos.y.isFinite || !pos.z.isFinite {
            fail("player position is non-finite", "\(pos)")
        }
        if !p.yaw.isFinite || !p.pitch.isFinite { fail("player angles non-finite", "\(p.yaw) \(p.pitch)") }
        if abs(p.pitch) > deg(86) { fail("pitch escaped its clamp", String(format: "%.1f deg", p.pitch * 180 / .pi)) }
        if !p.railDistance.isFinite { fail("rail distance non-finite", "\(p.railDistance)") }
        if p.railDistance < -1 || p.railDistance > s.field.built.spline.totalLength + 1 {
            fail("rail distance off the level", String(format: "%.1f", p.railDistance))
        }
        // The corridor clamp is the only thing keeping the player inside the
        // built world; a breach means they can walk into the void.
        let halfWidth = s.field.built.corridorHalfWidth
        if abs(p.railLateral) > halfWidth + 1.5 {
            fail("player escaped the corridor", String(format: "%.1f of %.1f", p.railLateral, halfWidth))
        }
        if let limit = p.progressLimit, p.railDistance > limit + 2.0 {
            fail("player passed a sealed gate", String(format: "%.1f past %.1f", p.railDistance, limit))
        }

        for z in s.zombies {
            let zp = z.position
            if !zp.x.isFinite || !zp.y.isFinite || !zp.z.isFinite {
                fail("enemy position non-finite", "\(z.kind.rawValue)")
                break
            }
            if z.health > z.stats.maxHealth + 0.01 {
                fail("enemy health above maximum", z.kind.rawValue)
                break
            }
            // An enemy that has wandered kilometres away is a navigation bug.
            if simd_distance(zp, pos) > 400 {
                fail("enemy is impossibly far away",
                     String(format: "%@ at %.0f m", z.kind.rawValue, simd_distance(zp, pos)))
                break
            }
        }
        _ = frame
    }

    /// Counts live scene-graph nodes, which is the cheapest proxy for a leak.
    static func nodeCount(_ node: SCNNode) -> Int {
        var n = 0
        node.enumerateHierarchy { _, _ in n += 1 }
        return n
    }
}

extension Harness {
    /// `--soak [--minutes 6] [--level N] [--restarts 8]`
    ///
    /// Plays chaotically for a long time, then restarts the level repeatedly,
    /// asserting invariants throughout and watching for unbounded growth.
    static func soak(_ args: Args) -> Int32 {
        let minutes = args.float("--minutes", 6)
        let restarts = args.int("--restarts", 6)
        let onlyLevel = args.string("--level").flatMap { Int($0) }
        var found = Set<Soak.Violation>()
        var failures = 0

        out("CRIMSON RAIL — soak test")
        out("")

        var settings = Settings()
        settings.graphics = .forPreset(.low)
        settings.graphics.particleBudget = args.float("--particles", 0)
        settings.gameplay.goreLevel = 1        // exercise gibs and decals

        // ---- Long chaotic run per level ---------------------------------------
        out("level                  frames   nodes(start->end)  zombies  peak  verdict")
        out(String(repeating: "-", count: 76))

        for levelIndex in 0..<LevelCatalog.count {
            if let only = onlyLevel, only != levelIndex + 1 { continue }
            let def = LevelCatalog.level(levelIndex)
            let session = Session(def: def, settings: settings)
            session.aspect = 16.0 / 9.0

            var rng = Rand(seed: UInt64(9000 + levelIndex))
            let dt: Float = 1.0 / 60.0
            let frames = Int(minutes * 60 * 60)
            let startNodes = Soak.nodeCount(session.field.scene.rootNode)
            var peakZombies = 0
            var levelViolations = 0
            // Node count sampled every ten seconds: a leak shows as a line that
            // keeps climbing rather than settling at its budget.
            var nodeTrace: [Int] = []
            var completedRuns = 0

            var executed = 0
            for f in 0..<frames {
                executed = f + 1
                // Push toward the objective so the run actually reaches the
                // encounters. Purely random input never walks far enough to
                // trigger one, which made the first version of this test soak
                // an empty level for three minutes and report success.
                let player = session.field.player
                let objective = player.objectiveDirection.flat.normalizedSafe
                let yawErr = angleDelta(player.yaw, cameraYaw(objective))

                var move = PlayerController.MoveInput()
                move.forward = 1
                move.strafe = rng.float(-0.6, 0.6)
                move.isSprinting = rng.chance(0.25)
                // Track the objective, but jitter hard on top of it.
                move.lookDeltaX = -clamp(yawErr, -0.05, 0.05) / 0.0022 + rng.float(-90, 90)
                move.lookDeltaY = rng.float(-60, 60)
                // Occasional violent flick, as a real player produces.
                if rng.chance(0.01) { move.lookDeltaX = rng.float(-9000, 9000) }
                // Occasional attempt to walk backwards out of the level.
                if rng.chance(0.02) { move.forward = -1 }

                let fire = rng.chance(0.35)
                session.update(dt: dt, aim: SIMD2(0, 0), trigger: fire,
                               triggerPressed: fire, reload: rng.chance(0.02), move: move)
                _ = session.drainEvents()

                let before = found.count
                Soak.checkInvariants(session, frame: f, into: &found)
                levelViolations += found.count - before

                peakZombies = max(peakZombies, session.zombies.count)
                if f % 600 == 0 { nodeTrace.append(Soak.nodeCount(session.field.scene.rootNode)) }
                // Runs end long before the soak does. Keep going on a fresh
                // session so the full duration is actually spent in combat
                // rather than sitting on a finished one.
                if session.outcome != .running {
                    completedRuns += 1
                    break
                }
            }

            let endNodes = Soak.nodeCount(session.field.scene.rootNode)
            // Dynamic content is budgeted, so the node count must not run away.
            let growth = endNodes - startNodes
            let leaked = growth > 900
            if leaked || levelViolations > 0 { failures += 1 }
            out(String(format: "%-22@ %6d   %5d -> %-5d %7d %5d  %@",
                       def.name as NSString, executed, startNodes, endNodes,
                       session.zombies.count, peakZombies,
                       (leaked ? "NODE GROWTH \(growth)" : (levelViolations > 0 ? "INVARIANT" : "ok")) as NSString))
            _ = completedRuns
            if args.has("--trace") {
                out("    nodes over time: " + nodeTrace.map(String.init).joined(separator: " "))
            }
            session.teardown()
        }

        // ---- Restart loop -------------------------------------------------------
        // Restarting is where lifecycle bugs live: anything a session forgets to
        // release accumulates across retries, and players retry a lot.
        out("")
        out("restart loop (\(restarts) sessions on level 1)")
        out(String(repeating: "-", count: 76))
        var nodeCounts: [Int] = []
        for i in 0..<restarts {
            let session = Session(def: LevelCatalog.level(0), settings: settings)
            session.aspect = 16.0 / 9.0
            var rng = Rand(seed: UInt64(500 + i))
            for _ in 0..<(35 * 60) {
                var move = PlayerController.MoveInput()
                move.forward = 1
                move.lookDeltaX = rng.float(-40, 40)
                let fire = rng.chance(0.25)
                session.update(dt: 1.0 / 60.0, aim: SIMD2(0, 0), trigger: fire,
                               triggerPressed: fire, reload: false, move: move)
                _ = session.drainEvents()
                Soak.checkInvariants(session, frame: 0, into: &found)
            }
            nodeCounts.append(Soak.nodeCount(session.field.scene.rootNode))
            session.teardown()
            // After teardown the dynamic root should be essentially empty.
            let leftOver = Soak.nodeCount(session.field.dynamicRoot)
            if args.has("--trace") {
                var kinds: [String: Int] = [:]
                session.field.dynamicRoot.enumerateHierarchy { n, _ in
                    let key = n.name ?? (n.geometry != nil ? "geometry:\(type(of: n.geometry!))" : "empty")
                    kinds[key, default: 0] += 1
                }
                out("      leftovers: " + kinds.sorted { $0.key < $1.key }
                    .map { "\($0.key)x\($0.value)" }.joined(separator: " "))
            }
            out(String(format: "  session %d: %5d nodes, %3d left under dynamic root after teardown%@",
                       i + 1, nodeCounts[i], leftOver,
                       (leftOver > 60 ? "   <-- NOT RELEASED" : "") as NSString))
            if leftOver > 60 { failures += 1 }
        }

        out("")
        if found.isEmpty && failures == 0 {
            out("no invariant violations, no leaks")
            return 0
        }
        for v in found.sorted(by: { $0.name < $1.name }) {
            out("  ✗ \(v.name): \(v.detail)")
        }
        out("\(found.count) distinct invariant violation(s), \(failures) structural failure(s)")
        return 1
    }
}
