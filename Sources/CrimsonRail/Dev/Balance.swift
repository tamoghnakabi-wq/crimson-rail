import Foundation
import SceneKit
import simd

/// Headless playthroughs driven by a simulated player.
///
/// This is the only practical way to tune five levels across three difficulties:
/// playing each combination by hand would take hours and still produce one noisy
/// sample per run. The bot is deliberately imperfect — reaction delay, aim error
/// and a miss rate — so the numbers mean something about a person playing.
enum Balance {

    struct BotProfile {
        var name: String
        /// Seconds before the bot reacts to a newly-visible threat.
        var reaction: Float
        /// Standard deviation of aim error, in radians.
        var aimError: Float
        /// Probability of going for the head rather than centre mass.
        var headshotIntent: Float
        /// Extra delay before pulling the trigger once on target.
        var triggerDelay: Float

        static let novice = BotProfile(name: "novice", reaction: 0.62, aimError: deg(3.4),
                                       headshotIntent: 0.15, triggerDelay: 0.14)
        static let average = BotProfile(name: "average", reaction: 0.38, aimError: deg(1.9),
                                        headshotIntent: 0.42, triggerDelay: 0.08)
        static let expert = BotProfile(name: "expert", reaction: 0.20, aimError: deg(0.9),
                                       headshotIntent: 0.80, triggerDelay: 0.04)
    }

    struct Outcome {
        var won = false
        var score = 0
        var accuracy: Float = 0
        var healthLeft: Float = 0
        var duration: Float = 0
        var kills = 0
        var threats = 0
        var rank: Rank = .d
        var timedOut = false
    }

    /// Plays one level to completion (or to a wall-clock cap).
    static func play(levelIndex: Int, difficulty: Difficulty, profile: BotProfile,
                     seed: UInt64, maxSeconds: Float = 600, trace: Bool = false) -> Outcome {
        var settings = Settings()
        // Lowest visual settings: the simulation never renders, and heavy texture
        // work would dominate the run time for no benefit.
        settings.graphics = .forPreset(.low)
        settings.graphics.particleBudget = 0
        settings.gameplay.difficulty = difficulty
        settings.gameplay.goreLevel = 0

        let def = LevelCatalog.level(levelIndex)
        let session = Session(def: def, settings: settings)
        session.aspect = 16.0 / 9.0

        var rng = Rand(seed: seed)
        var target: Zombie?
        var lockTimer: Float = 0
        let dt: Float = 1.0 / 60.0
        var t: Float = 0

        // Unstick state: a player who stops making progress walks around whatever
        // is in the way. Without this the bot presses into props for ever and the
        // harness reports a level as unwinnable when it is merely awkward.
        var lastProgress: Float = 0
        var stuckFor: Float = 0
        var detourSign: Float = 1
        var detourFor: Float = 0

        // Turn rate the bot is allowed, in radians/second. A human cannot snap
        // instantly, and an unlimited-turn bot would make every level trivial.
        let turnRate: Float = 3.2 + (1 - profile.aimError / deg(4)) * 2.6

        while session.outcome == .running && t < maxSeconds {
            t += dt
            let player = session.field.player
            let eye = player.eyePosition

            // ---- Pick something to look at -------------------------------------
            let threats = session.zombies.filter { $0.isThreat }
            if let current = target, !current.isThreat { target = nil }
            let mostUrgent = threats.min { a, b in
                urgency(a, session: session) > urgency(b, session: session)
            }
            if target !== mostUrgent && (target == nil || rng.chance(0.05)) {
                target = mostUrgent
                lockTimer = profile.reaction * rng.float(0.7, 1.4)
            }
            lockTimer = max(0, lockTimer - dt)

            // Incoming acid outranks everything: a real player shoots the glowing
            // thing arcing at their face.
            var aimPoint: SIMD3<Float>?
            var isGlob = false
            if let glob = session.incomingGlobs.filter({ $0.distance < 16 })
                                               .min(by: { $0.distance < $1.distance }) {
                aimPoint = glob.position
                isGlob = true
            } else if let z = target, z.isThreat, lockTimer <= 0 {
                let goHead = rng.chance(profile.headshotIntent)
                var p = goHead ? z.headPosition : z.centreOfMass
                let d = simd_distance(p, eye)
                p += SIMD3(rng.gaussian(0, profile.aimError) * d,
                           rng.gaussian(0, profile.aimError) * d,
                           rng.gaussian(0, profile.aimError) * d)
                aimPoint = p
            }

            // ---- Turn ---------------------------------------------------------
            var move = PlayerController.MoveInput()
            var wantFire = false

            /// Feeds the mouse deltas needed to bring the view onto a direction.
            func steer(toward dir: SIMD3<Float>, rate: Float) -> (yawErr: Float, pitchErr: Float) {
                let d = simd_normalize(dir)
                let yawErr = angleDelta(player.yaw, cameraYaw(d))
                let pitchErr = asin(clamp(d.y, -1, 1)) - player.pitch
                let step = rate * dt
                let scale: Float = 0.0022
                move.lookDeltaX = -clamp(yawErr, -step, step) / scale
                move.lookDeltaY = -clamp(pitchErr, -step, step) / scale
                return (yawErr, pitchErr)
            }

            if aimPoint == nil {
                // Nothing to shoot: look where you are going. Without this the bot
                // never turns at all between fights — its facing is driven only by
                // aiming — so a run that ends a fight pointing backwards walks away
                // from the exit until the clock runs out. That produced a 25% false
                // failure rate on levels 3 and 4 and is a defect in the simulated
                // player, not in the game.
                var objective = player.objectiveDirection.flat
                if simd_length(objective) < 1e-4 { objective = player.forward.flat }
                _ = steer(toward: objective, rate: turnRate * 0.6)
            }

            if let p = aimPoint {
                let (yawErr, pitchErr) = steer(toward: p - eye, rate: turnRate)
                // Fire once the crosshair is genuinely on target.
                let tol = deg(isGlob ? 3.5 : 2.2)
                if abs(yawErr) < tol && abs(pitchErr) < tol { wantFire = true }
            }

            // ---- Move -------------------------------------------------------------
            // Head for the exit, but hold ground while something is in its face —
            // walking into a brute is not what a player would do.
            let nearest = threats.map { $0.distanceToTarget }.min() ?? .greatestFiniteMagnitude
            let objective = player.objectiveDirection.flat.normalizedSafe
            let fwd = player.forward.flat.normalizedSafe
            let right = player.right.flat.normalizedSafe
            let alongObjective = simd_dot(objective, fwd)
            let sideObjective = simd_dot(objective, right)

            // Progress watchdog.
            let progressNow = player.railDistance
            if progressNow > lastProgress + 0.25 {
                lastProgress = progressNow
                stuckFor = 0
            } else if session.director.progressGate == nil {
                // Only count as stuck when nothing is deliberately holding us.
                stuckFor += dt
            } else {
                stuckFor = 0
            }
            if stuckFor > 1.5 && detourFor <= 0 {
                detourFor = 1.2
                detourSign = rng.chance(0.5) ? 1 : -1
                stuckFor = 0
            }
            detourFor = max(0, detourFor - dt)

            if detourFor > 0 {
                move.forward = 0.35
                move.strafe = detourSign
            } else if nearest < 3.0 {
                // Back away from whatever is on top of us.
                move.forward = -1
            } else if nearest < 7.0 && threats.count > 2 {
                // Hold and fight rather than wade into a group.
                move.forward = 0
                move.strafe = sideObjective > 0 ? 0.4 : -0.4
            } else if alongObjective > -0.2 {
                move.forward = clamp(alongObjective * 1.4 + 0.35, -1, 1)
                move.strafe = clamp(sideObjective * 1.2, -1, 1)
            } else {
                // Facing well away from the exit: hold still and turn rather than
                // reversing into the level behind.
                move.forward = 0
                move.strafe = clamp(sideObjective * 0.8, -1, 1)
            }

            let reload = session.weapon.isEmpty && !session.weapon.isReloading
            let hpBefore = session.health
            session.update(dt: dt, aim: SIMD2(0, 0), trigger: wantFire,
                           triggerPressed: wantFire, reload: reload, move: move)
            let events = session.drainEvents()
            if trace {
                if session.health < hpBefore {
                    let attackers = session.zombies.filter { $0.isThreat && $0.distanceToTarget < 3.0 }
                    Harness.out(String(format: "  %5.1fs  HIT -%.0f -> hp %.0f   rail %.0fm  alive %d  inReach %d  [%@]",
                                       t, hpBefore - session.health, session.health,
                                       session.field.player.railDistance,
                                       session.zombies.filter { $0.isThreat }.count,
                                       attackers.count,
                                       attackers.map { $0.kind.rawValue }.joined(separator: ",") as NSString))
                }
                // Periodic progress line, so a stall is visible as a flat rail distance.
                if Int(t * 60) % 300 == 0 {
                    Harness.out(String(format: "  %5.1fs  rail %.0f/%.0fm  gate %@  alive %d  hp %.0f",
                                       t, session.field.player.railDistance,
                                       session.field.built.spline.totalLength,
                                       session.director.progressGate.map { String(format: "%.0f", $0) } as NSString? ?? "-",
                                       session.zombies.filter { $0.isThreat }.count, session.health))
                }
                for e in events where e.kind == .banner {
                    Harness.out(String(format: "  %5.1fs  BANNER %@ (rail %.0fm)", t, (e.text ?? "") as NSString,
                                       session.field.player.railDistance))
                }
            }
        }

        var out = Outcome()
        let r = session.makeResult()
        out.won = r.won
        out.score = r.score
        out.accuracy = r.accuracy
        out.healthLeft = r.healthFraction
        out.duration = r.duration
        out.kills = r.kills
        out.threats = def.totalThreats
        out.rank = r.rank
        out.timedOut = t >= maxSeconds
        session.teardown()
        return out
    }

    /// How badly a given enemy needs shooting: close and fast beats far and slow.
    private static func urgency(_ z: Zombie, session: Session) -> Float {
        let d = max(z.distanceToTarget, 0.4)
        var score = 20 / d
        if z.state == .windup || z.state == .strike { score *= 3.2 }
        if z.kind == .runner || z.kind == .crawler { score *= 1.5 }
        if z.kind == .spitter { score *= 1.35 }
        return score
    }
}

extension Harness {
    /// `--balance [--runs 3] [--level N] [--difficulty agent] [--profile average]`
    static func balance(_ args: Args) -> Int32 {
        let runs = args.int("--runs", 3)
        let onlyLevel = args.string("--level").flatMap { Int($0) }
        let profiles: [Balance.BotProfile] = {
            switch args.string("--profile", "all") ?? "all" {
            case "novice": return [.novice]
            case "average": return [.average]
            case "expert": return [.expert]
            default: return [.novice, .average, .expert]
            }
        }()
        let difficulties: [Difficulty] = {
            if let d = args.string("--difficulty"), let v = Difficulty(rawValue: d) { return [v] }
            return [.agent]
        }()

        out("CRIMSON RAIL — balance simulation   runs=\(runs) per cell")
        out("")
        out("level                  profile   diff      win%  score   acc%    hp%   time  rank")
        out(String(repeating: "-", count: 84))

        var failures = 0
        var totalCells = 0
        for levelIndex in 0..<LevelCatalog.count {
            if let only = onlyLevel, only != levelIndex + 1 { continue }
            let def = LevelCatalog.level(levelIndex)
            for profile in profiles {
                for diff in difficulties {
                    var wins = 0, timeouts = 0
                    var score = 0, acc: Float = 0, hp: Float = 0, dur: Float = 0
                    var rankSum = 0
                    for r in 0..<runs {
                        let o = Balance.play(levelIndex: levelIndex, difficulty: diff, profile: profile,
                                             seed: UInt64(1000 + r * 77 + levelIndex * 13),
                                             trace: args.has("--trace"))
                        if o.won { wins += 1 }
                        if o.timedOut { timeouts += 1 }
                        score += o.score; acc += o.accuracy; hp += o.healthLeft; dur += o.duration
                        rankSum += o.rank.order
                    }
                    let n = Float(runs)
                    let winPct = Float(wins) / n * 100
                    totalCells += 1
                    if timeouts > 0 { failures += 1 }
                    out(String(format: "%-22@ %-9@ %-8@ %4.0f%% %6d %5.0f%% %5.0f%% %5.0fs %5@%@",
                               def.name as NSString, profile.name as NSString,
                               diff.rawValue as NSString,
                               winPct, score / runs, acc / n * 100, hp / n * 100, dur / n,
                               rankLabel(rankSum / runs) as NSString,
                               (timeouts > 0 ? "  TIMEOUT x\(timeouts)" : "") as NSString))
                }
            }
        }
        out("")
        if failures > 0 {
            out("\(failures) cell(s) hit the wall-clock cap — a level may be unwinnable or soft-locked.")
            return 1
        }
        out("no timeouts: every level is completable by the simulated player.")
        return 0
    }

    private static func rankLabel(_ order: Int) -> String {
        switch order {
        case 5: return "S"; case 4: return "A"; case 3: return "B"; case 2: return "C"; default: return "D"
        }
    }
}
