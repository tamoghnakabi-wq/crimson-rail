import Foundation
import SceneKit
import AppKit
import simd

/// One enemy: its body, its animation, and its behaviour.
///
/// Model convention: the body is authored facing **local +Z** (brow, eyes and
/// jaw all sit at positive z), so `root` yaw comes straight from `yawToward`.
/// Joints swing about local X, and a forward swing is a *negative* angle.
final class Zombie {
    enum State {
        case emerging       // spawn flourish; not yet a threat
        case approach
        case windup         // telegraph before a strike
        case strike
        case recover
        case stagger        // hit reaction
        case dying
        case dead
    }

    let kind: ZombieKind
    let stats: ZombieStats
    let body: ZombieBody
    var node: SCNNode { body.root }

    private(set) var state: State = .emerging
    private(set) var health: Float
    private(set) var isDead = false
    /// Set once the death animation has finished and the corpse can be culled.
    private(set) var corpseAge: Float = 0

    /// Ground position. Y comes from the level's ground sampler.
    var position: SIMD3<Float>
    private var facing: Float
    private var velocity: SIMD3<Float> = .zero

    // Animation state
    private var walkPhase: Float
    private var stateTime: Float = 0
    private var emergeDuration: Float = 1.0
    private let entrance: SpawnDef.Entrance
    /// Per-instance asymmetry: the limp that stops a crowd looking synchronised.
    private let limp: Float
    private let gaitOffset: Float
    private let leanBase: Float
    private let armDroop: Float
    private let speedScale: Float

    // Combat
    private var attackCooldown: Float = 0
    private var staggerRemaining: Float = 0
    private var lastHitZone: HitZone = .torso
    private var deathSpin: Float = 0
    private var deathPitch: Float = 0
    private var deathFallDirection: Float = 1
    private var deathStyle: DeathStyle = .backward
    private var deathDrop: Float = 0
    private var deathRoll: Float = 0
    /// Direction the killing shot came from, so the body is thrown by it.
    private var deathImpulse: SIMD3<Float> = .zero
    /// Brief per-hit flinch, drives a whole-body jolt.
    private var flinch: Float = 0
    private var flinchDir: Float = 1

    /// How a body goes down. Varying this is most of what stops a pile of
    /// corpses looking stamped from one mould.
    private enum DeathStyle { case backward, forward, crumple, spin }
    /// True once this one has landed a hit in the current strike.
    private var strikeResolved = false

    /// Set by the director; the point on the ground this enemy walks toward.
    var targetProvider: () -> SIMD3<Float> = { .zero }
    var groundSampler: (SIMD3<Float>) -> Float = { _ in 0 }

    /// Callbacks into the game, set at spawn time.
    var onStrike: ((Zombie) -> Void)?
    var onSpit: ((Zombie, SIMD3<Float>) -> Void)?
    var onDeath: ((Zombie) -> Void)?

    private var rng: Rand

    init(kind: ZombieKind, position: SIMD3<Float>, facing: Float,
         entrance: SpawnDef.Entrance, difficulty: Difficulty, seed: UInt64) {
        self.kind = kind
        self.stats = kind.stats
        self.body = ZombieBody(kind: kind, seed: seed)
        self.position = position
        self.facing = facing
        self.entrance = entrance
        self.health = stats.maxHealth
        var r = Rand(seed: seed &+ 977)
        self.walkPhase = r.float(0, 2 * .pi)
        self.limp = r.float(0.0, 0.35)
        self.gaitOffset = r.float(-0.35, 0.35)
        self.leanBase = deg(r.float(20, 38))
        self.armDroop = r.float(0.0, 1.0)
        self.speedScale = r.float(0.88, 1.14) * difficulty.enemyAggression
        self.rng = r

        body.root.simdPosition = position
        body.root.simdOrientation = simd_quatf(angle: facing, axis: SIMD3(0, 1, 0))

        switch entrance {
        case .lurch: emergeDuration = 0.55
        case .riseFromGround: emergeDuration = 1.7
        case .burstThrough: emergeDuration = 0.65
        case .dropFromAbove: emergeDuration = 0.85
        }
        if kind == .warden { emergeDuration = 2.6 }
    }

    // MARK: Queries

    var isThreat: Bool { !isDead && state != .dead && state != .dying }
    /// Roughly where a bullet should spray blood from when zone is unknown.
    var centreOfMass: SIMD3<Float> {
        body.chest.simdWorldPosition
    }
    var headPosition: SIMD3<Float> { body.head.simdWorldPosition }
    var distanceToTarget: Float { position.flatDistance(to: targetProvider()) }

    // MARK: Frame

    func update(dt: Float, elapsed: Float, neighbours: [Zombie]) {
        stateTime += dt
        attackCooldown = max(0, attackCooldown - dt)

        switch state {
        case .emerging: updateEmerging(dt: dt)
        case .approach: updateApproach(dt: dt, neighbours: neighbours)
        case .windup: updateWindup(dt: dt)
        case .strike: updateStrike(dt: dt)
        case .recover:
            if stateTime > stats.recovery / max(speedScale, 0.4) { enter(.approach) }
        case .stagger:
            staggerRemaining -= dt
            if staggerRemaining <= 0 { enter(.approach) }
        case .dying:
            updateDying(dt: dt)
        case .dead:
            corpseAge += dt
        }

        if kind == .warden { body.pulseWeakPoints(elapsed) }
        pose(dt: dt)
        applyTransform()
    }

    private func enter(_ s: State) {
        state = s
        stateTime = 0
        if s == .strike { strikeResolved = false }
    }

    // MARK: Behaviour

    private func updateEmerging(dt: Float) {
        if stateTime >= emergeDuration { enter(.approach) }
    }

    private func updateApproach(dt: Float, neighbours: [Zombie]) {
        let target = targetProvider()
        let toTarget = (target - position).flat
        let dist = simd_length(toTarget)

        if dist <= stats.attackReach && attackCooldown <= 0 {
            enter(.windup)
            return
        }

        var dir = toTarget.normalizedSafe
        // Separation, so a wave does not converge into one flickering pile. Only
        // near neighbours matter, and the push is capped so it never overrides
        // the approach entirely.
        var push = SIMD3<Float>.zero
        for other in neighbours where other !== self && other.isThreat {
            let delta = (position - other.position).flat
            let d = simd_length(delta)
            let minGap: Float = 0.95 * (stats.scale + other.stats.scale) * 0.5
            if d < minGap && d > 1e-3 {
                push += delta / d * ((minGap - d) / minGap)
            }
        }
        if simd_length(push) > 1e-4 {
            dir = simd_normalize(dir + push.normalizedSafe * min(simd_length(push), 1.0) * 0.85)
        }

        // Enemies no longer funnel into a forward arc. That existed only because
        // the rail camera could not turn, so anything closing from the side was
        // unshootable; with free look, being surrounded is a fair threat and the
        // damage indicator tells the player where it came from.

        // Spitters hold their ground once in range and open fire instead.
        if stats.isRanged {
            let preferred: Float = 11
            if dist < preferred - 1.5 {
                dir = -dir
            } else if dist < stats.attackReach {
                if attackCooldown <= 0 { enter(.windup); return }
                dir = .zero
            }
        }

        let speed = stats.moveSpeed * speedScale
        velocity = dir * speed
        position += velocity * dt
        position.y = groundSampler(position)

        if simd_length(dir) > 1e-3 {
            // Turn toward the direction of travel, but always keep facing the
            // player enough to read as menacing.
            let desired = yawToward((target - position).flat.normalizedSafe)
            facing += angleDelta(facing, desired) * (1 - exp(-6 * dt))
        }
        walkPhase += dt * speed * 2.4
    }

    private func updateWindup(dt: Float) {
        let windup = stats.windup / max(speedScale, 0.5)
        // Keep tracking the player during the telegraph so a hold-still player
        // cannot simply be missed.
        let target = targetProvider()
        let desired = yawToward((target - position).flat.normalizedSafe)
        facing += angleDelta(facing, desired) * (1 - exp(-4 * dt))
        if stateTime >= windup { enter(.strike) }
    }

    private func updateStrike(dt: Float) {
        let strikeDuration: Float = stats.isRanged ? 0.30 : 0.26
        // The hit lands partway through, not at the start — that gap is the
        // player's last chance to kill it first.
        if !strikeResolved && stateTime >= strikeDuration * 0.55 {
            strikeResolved = true
            if stats.isRanged {
                onSpit?(self, targetProvider())
            } else if distanceToTarget <= stats.attackReach * 1.25 {
                onStrike?(self)
            }
        }
        if !stats.isRanged {
            // Lunge: a short burst of forward movement so the attack has weight.
            let lungeSpeed: Float = 2.6 * (1 - stateTime / strikeDuration)
            let fwd = SIMD3<Float>(sin(facing), 0, cos(facing))
            position += fwd * max(lungeSpeed, 0) * dt
            position.y = groundSampler(position)
        }
        if stateTime >= strikeDuration {
            attackCooldown = stats.recovery / max(speedScale, 0.5)
            enter(.recover)
        }
    }

    private func updateDying(dt: Float) {
        // Each style falls at its own rate and settles differently.
        let rate: Float
        switch deathStyle {
        case .backward: rate = 3.1
        case .forward: rate = 3.9
        case .crumple: rate = 5.2      // legs give out: fast, straight down
        case .spin: rate = 2.7
        }
        deathPitch = min(deathPitch + dt * rate, .pi / 2)
        // Crumpling drops the body's height as the legs fold under it.
        if deathStyle == .crumple {
            deathDrop = min(deathDrop + dt * 1.9, 0.62)
        } else {
            deathDrop = min(deathDrop + dt * 0.5, 0.16)
        }
        deathRoll += dt * deathSpin * 1.4
        // Carried by the shot for the first moment.
        position += deathImpulse * dt
        deathImpulse *= (1 - min(dt * 5.5, 1))
        position.y = groundSampler(position)

        if deathPitch >= .pi / 2 - 0.01 {
            enter(.dead)
            body.setEyeGlow(0)
        }
    }

    // MARK: Damage

    struct DamageResult {
        var applied: Float
        var killed: Bool
        var zone: HitZone
        var absorbed: Bool     // armour stopped it
        var severed: SCNNode?  // limb that came off
    }

    @discardableResult
    func applyDamage(_ amount: Float, zone: HitZone, partIndex: Int?, allowSever: Bool,
                     impactDirection: SIMD3<Float> = SIMD3(0, 0, 1)) -> DamageResult {
        guard isThreat else {
            return DamageResult(applied: 0, killed: false, zone: zone, absorbed: false, severed: nil)
        }
        var multiplier: Float
        switch zone {
        case .head: multiplier = stats.headMultiplier
        case .torso: multiplier = stats.torsoMultiplier
        case .arm, .leg: multiplier = stats.limbMultiplier
        }

        var absorbed = false
        if zone == .torso && stats.torsoArmor > 0 {
            multiplier *= (1 - stats.torsoArmor)
            absorbed = true
        }

        let dealt = amount * multiplier
        health -= dealt
        lastHitZone = zone

        var severed: SCNNode?
        // Limbs come off when the shot would have been lethal to the limb itself,
        // or on the killing blow — messy, but not on every graze.
        if allowSever, let idx = partIndex, zone.isLimb,
           (health <= 0 || dealt > stats.maxHealth * 0.35) {
            severed = body.sever(partIndex: idx)
        }

        if health <= 0 {
            die(fromZone: zone, from: impactDirection)
            return DamageResult(applied: dealt, killed: true, zone: zone, absorbed: absorbed, severed: severed)
        }

        // Flinch. Heavier archetypes barely react, which is what makes them read
        // as heavy; light ones are interruptible, which is what makes them fair.
        // Every hit jolts the body, even one that does not interrupt it. Without
        // that, shooting a brute reads as shooting a wall.
        flinch = zone == .head ? 1.0 : 0.7
        flinchDir = rng.chance(0.5) ? 1 : -1
        let staggerChance = (1 - stats.staggerResistance) * (zone == .head ? 1.0 : 0.6)
        if state != .strike && rng.chance(staggerChance) {
            staggerRemaining = zone == .head ? 0.5 : 0.34
            enter(.stagger)
        }
        return DamageResult(applied: dealt, killed: false, zone: zone, absorbed: absorbed, severed: severed)
    }

    private func die(fromZone zone: HitZone, from direction: SIMD3<Float>) {
        isDead = true
        enter(.dying)
        // A headshot cuts the strings: the body drops where it stands. Anything
        // else throws it, and a leg shot folds it.
        if zone == .head {
            deathStyle = .crumple
        } else if zone == .leg {
            deathStyle = rng.chance(0.6) ? .crumple : .forward
        } else {
            deathStyle = rng.chance(0.65) ? .backward : (rng.chance(0.5) ? .forward : .spin)
        }
        deathFallDirection = deathStyle == .forward ? -1 : 1
        deathSpin = rng.float(-0.9, 0.9)
        // Momentum from the shot, biggest on a heavy body shot.
        let push: Float = zone == .head ? 0.5 : (stats.staggerResistance > 0.6 ? 0.6 : 1.9)
        deathImpulse = direction.flat.normalizedSafe * push
        body.setEyeGlow(0.15)
        onDeath?(self)
    }

    /// Harness hook: jump straight to a named state so a pose can be inspected.
    func debugForceState(_ name: String) {
        switch name {
        case "windup": enter(.windup)
        case "strike": enter(.strike)
        case "stagger": staggerRemaining = 0.45; lastHitZone = .head; enter(.stagger)
        case "recover": enter(.recover)
        case "dying": isDead = true; deathFallDirection = 1; enter(.dying)
        case "emerging": enter(.emerging)
        default: enter(.approach)
        }
    }

    /// Instantly removes the enemy without a death animation (level teardown).
    func despawn() {
        node.removeFromParentNode()
        isDead = true
        state = .dead
    }

    // MARK: Pose
    //
    // All animation is written directly onto joint quaternions each frame rather
    // than played back from clips. For a cast this small it costs less than an
    // animation system, and it makes state blends (a stagger interrupting a
    // stride) trivial to express.

    private func pose(dt: Float) {
        let s = stats
        var lean = leanBase
        var hipDrop: Float = 0
        // Arms carried well out in front — the reaching silhouette is the single
        // most recognisable thing about this enemy at a distance.
        var armForward: Float = deg(-74) + armDroop * deg(26)
        var elbowBend: Float = deg(-52)
        var headTilt: Float = deg(14)

        // Walk cycle. `stride` collapses to zero when standing so the same code
        // covers moving and stationary poses.
        let strideAmp: Float = {
            switch state {
            case .approach: return kind == .runner ? 0.95 : 0.68
            case .windup, .strike, .recover: return 0.18
            default: return 0.12
            }
        }()

        let phase = walkPhase
        let lSwing = sin(phase) * strideAmp
        let rSwing = sin(phase + .pi) * strideAmp * (1 - limp * 0.55)
        // Knees only bend on the return stroke.
        let lKnee = max(0, -sin(phase + 0.7)) * strideAmp * 1.35
        let rKnee = max(0, -sin(phase + .pi + 0.7)) * strideAmp * 1.35 * (1 - limp * 0.4)
        hipDrop = -abs(sin(phase)) * 0.035 * strideAmp

        switch state {
        case .emerging:
            let t = clamp01(stateTime / emergeDuration)
            switch entrance {
            case .riseFromGround:
                // Claws up out of the soil: sunk below the surface, hauling itself out.
                hipDrop -= (1 - smoothstep(0, 1, t)) * 1.35
                lean += (1 - t) * deg(55)
                armForward = deg(-118) + t * deg(44)
                elbowBend = deg(-20)
            case .dropFromAbove:
                lean += (1 - t) * deg(-30)
                armForward = deg(-96)
            case .burstThrough:
                lean += (1 - smoothstep(0, 1, t)) * deg(-38)
                armForward = deg(-112) + t * deg(38)
            case .lurch:
                lean += (1 - t) * deg(14)
            }

        case .windup:
            let t = clamp01(stateTime / (s.windup / max(speedScale, 0.5)))
            let e = smoothstep(0, 1, t)
            if s.isRanged {
                // Spitter rears its head back before launching.
                lean -= e * deg(26)
                headTilt -= e * deg(34)
                armForward = deg(-20)
            } else {
                // Rear back and raise the arms: the readable "it is about to hit you".
                lean -= e * deg(20)
                armForward = deg(-74) - e * deg(52)
                elbowBend = deg(-52) + e * deg(40)
                headTilt += e * deg(10)
            }

        case .strike:
            let t = clamp01(stateTime / 0.26)
            // Fast out, slow back: the impulse should feel snapped, not swung.
            let e = t < 0.4 ? smoothstep(0, 0.4, t) : 1 - smoothstep(0.4, 1, t) * 0.55
            lean += e * deg(34)
            armForward = deg(-126) + e * deg(104)
            elbowBend = deg(-12)
            headTilt -= e * deg(16)

        case .recover:
            let t = clamp01(stateTime / max(s.recovery, 0.01))
            lean += (1 - t) * deg(16)
            armForward = deg(-74) - (1 - t) * deg(18)

        case .stagger:
            // Snap away from the shot, then settle.
            let t = 1 - clamp01(staggerRemaining / 0.45)
            let jolt = sin(t * .pi * 2.5) * (1 - t)
            lean -= jolt * deg(26)
            headTilt += jolt * deg(30) * (lastHitZone == .head ? 1.8 : 1.0)
            armForward = deg(-74) + jolt * deg(38)

        case .dying, .dead:
            // Limp: the arms fall, the spine slackens, the knees give.
            let t = clamp01(deathPitch / (.pi / 2))
            lean = lerp(leanBase, deg(6), t)
            armForward = lerp(deg(-74), deg(-8), t)
            elbowBend = lerp(deg(-52), deg(-14), t)
            headTilt = lerp(deg(14), deg(-26), t)
            if deathStyle == .crumple { hipDrop -= deathDrop * 0.5 }

        default:
            break
        }

        // Crawlers are pitched right over onto their hands the whole time.
        if kind == .crawler && state != .dying && state != .dead {
            lean += deg(50)
            hipDrop -= 0.20
            armForward = deg(-16) + sin(phase) * 0.5
            elbowBend = deg(-30)
            headTilt -= deg(38)
        }

        // ---- Flinch ----------------------------------------------------------
        // A short, sharp jolt through the spine on every bullet that lands.
        flinch = max(0, flinch - dt * 5.5)
        if flinch > 0 && state != .dying && state != .dead {
            let j = sin(flinch * .pi * 2.2) * flinch
            lean -= j * deg(11)
            headTilt += j * deg(16) * flinchDir
            armForward += j * deg(9)
        }

        // ---- Write the pose -------------------------------------------------
        body.hips.simdPosition = SIMD3(0, hipsRestY + hipDrop, 0)
        body.hips.simdOrientation = simd_quatf(angle: lean * 0.35, axis: SIMD3(1, 0, 0))
        body.chest.simdOrientation =
            simd_quatf(angle: lean * 0.65, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: sin(phase) * 0.09 * strideAmp, axis: SIMD3(0, 1, 0))
        body.neck.simdOrientation = simd_quatf(angle: -lean * 0.55 + headTilt, axis: SIMD3(1, 0, 0))
        body.head.simdOrientation = simd_quatf(angle: sin(phase * 0.5 + gaitOffset) * 0.10, axis: SIMD3(0, 0, 1))

        for (i, arm) in body.upperArm.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            let sway = sin(phase + (i == 0 ? 0 : .pi)) * 0.22 * strideAmp
            arm.simdOrientation =
                simd_quatf(angle: armForward + sway - lean * 0.30, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: side * (deg(19) + armDroop * deg(12)), axis: SIMD3(0, 0, 1))
            body.lowerArm[i].simdOrientation = simd_quatf(angle: elbowBend, axis: SIMD3(1, 0, 0))
        }

        // Legs: negative X swings the limb forward (see the convention note above).
        body.thigh[0].simdOrientation = simd_quatf(angle: -lSwing * 0.55 - lean * 0.25, axis: SIMD3(1, 0, 0))
        body.thigh[1].simdOrientation = simd_quatf(angle: -rSwing * 0.55 - lean * 0.25, axis: SIMD3(1, 0, 0))
        if state == .dying || state == .dead {
            let t = clamp01(deathPitch / (.pi / 2))
            let fold = deathStyle == .crumple ? deg(96) : deg(38)
            body.thigh[0].simdOrientation = simd_quatf(angle: -deg(22) * t, axis: SIMD3(1, 0, 0))
            body.thigh[1].simdOrientation = simd_quatf(angle: -deg(16) * t, axis: SIMD3(1, 0, 0))
            body.shin[0].simdOrientation = simd_quatf(angle: fold * t, axis: SIMD3(1, 0, 0))
            body.shin[1].simdOrientation = simd_quatf(angle: fold * t * 0.86, axis: SIMD3(1, 0, 0))
        } else {
            body.shin[0].simdOrientation = simd_quatf(angle: lKnee * 0.9, axis: SIMD3(1, 0, 0))
            body.shin[1].simdOrientation = simd_quatf(angle: rKnee * 0.9, axis: SIMD3(1, 0, 0))
        }
    }

    private var hipsRestY: Float {
        // Cached from the body's construction; hips sit at a fixed local height.
        body.hipsRestY
    }

    private func applyTransform() {
        var p = position
        if state == .dying || state == .dead {
            // Sink as it falls, so the body settles into the ground rather than
            // pivoting on its heels like a felled tree.
            p.y -= deathDrop * 0.55
        }
        if state == .emerging, entrance == .dropFromAbove {
            // Falls the last stretch to the ground.
            let t = clamp01(stateTime / emergeDuration)
            p.y += (1 - t * t) * 3.2
        }
        node.simdPosition = p

        var q = simd_quatf(angle: facing, axis: SIMD3(0, 1, 0))
        if state == .dying || state == .dead {
            // Topple about the local X axis, with a little spin so a pile of
            // corpses does not look stamped from one mould.
            q = q * simd_quatf(angle: deathPitch * deathFallDirection, axis: SIMD3(1, 0, 0))
                  * simd_quatf(angle: deathRoll, axis: SIMD3(0, 0, 1))
                  * simd_quatf(angle: deathStyle == .spin ? deathSpin * deathPitch * 1.6 : 0,
                               axis: SIMD3(0, 1, 0))
        }
        node.simdOrientation = q
    }
}
