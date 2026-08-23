import Foundation
import SceneKit
import AppKit
import simd

/// One playthrough of one level: the world, everything alive in it, the
/// player's weapon and health, and the score.
final class Session {
    enum Outcome { case running, won, lost }

    let field: Playfield
    let effects: Effects
    let director: Director
    let def: LevelDef
    private let difficulty: Difficulty
    private var gameplay: GameplaySettings

    private(set) var weapon = Weapon()
    private(set) var outcome: Outcome = .running

    // Player
    private(set) var health: Float
    let maxHealth: Float
    /// Brief window after taking a hit during which further hits are ignored, so
    /// a pack cannot delete the player in three frames.
    private var damageImmunity: Float = 0
    private(set) var lastDamageDirection: SIMD3<Float> = .zero
    private(set) var damageFlash: Float = 0

    // Cast
    private(set) var zombies: [Zombie] = []
    /// Which encounter spawned each enemy, by encounter ID. `nil` means an
    /// ambush, which belongs to no encounter and gates nothing.
    ///
    /// Tagged by ID rather than by a bare "is encounter" flag on purpose: when a
    /// hold times out via its failsafe, its stuck enemies survive. A boolean tag
    /// leaves them counting towards *every later* encounter's clear condition,
    /// so each subsequent encounter also has to wait out its own failsafe. An ID
    /// cannot match the encounter that comes after it, so the contamination is
    /// impossible rather than merely unlikely.
    private var encounterTags: [ObjectIdentifier: String] = [:]
    private var survivor: SurvivorActor?
    private var globs: [AcidGlob] = []

    // Score
    private(set) var score = 0
    private(set) var combo = 0
    private(set) var bestCombo = 0
    private(set) var shots = 0
    private(set) var hits = 0
    private(set) var kills = 0
    private(set) var headshots = 0
    private(set) var survivorsSaved = 0
    private(set) var survivorsLost = 0
    private(set) var elapsed: Float = 0
    /// Reset combo if the player goes this long without a hit.
    private var comboTimer: Float = 0
    /// Seconds spent at the end of the rail with the schedule complete.
    private var endGrace: Float = 0

    /// Transient feedback the HUD reads and clears.
    private(set) var events: [FeedbackEvent] = []

    private var rng = Rand(seed: 0xCAFE)
    /// Audio hooks, injected by the game layer.
    var audio: AudioDirector?

    struct FeedbackEvent {
        enum Kind { case hit, headshot, kill, armorPing, playerHurt, survivorHurt, banner, reloadDone, dryFire, pickup }
        var kind: Kind
        var text: String?
        var worldPosition: SIMD3<Float>?
        var value: Int
    }

    init(def: LevelDef, settings: Settings) {
        self.def = def
        self.difficulty = settings.gameplay.difficulty
        self.gameplay = settings.gameplay
        field = Playfield(def: def, quality: settings.graphics, gameplay: settings.gameplay)
        effects = Effects(scene: field.scene, root: field.dynamicRoot,
                          quality: field.quality, gore: settings.gameplay.goreLevel)
        director = Director(def: def)
        maxHealth = difficulty.startingHealth
        health = maxHealth
        effects.attachMuzzle(to: field.cameraNode)
        field.player.onFootstep = { [weak self] in self?.audio?.play(.footstep) }
    }

    // MARK: Frame

    func update(dt: Float, aim: SIMD2<Float>, trigger: Bool, triggerPressed: Bool, reload: Bool,
                move: PlayerController.MoveInput = .init()) {
        guard outcome == .running else { return }
        elapsed += dt
        damageImmunity = max(0, damageImmunity - dt)
        damageFlash = max(0, damageFlash - dt * 2.2)

        // ---- Weapon -----------------------------------------------------------
        weapon.update(dt: dt)
        if weapon.justFinishedReload {
            events.append(FeedbackEvent(kind: .reloadDone, text: nil, worldPosition: nil, value: 0))
            audio?.play(.reloadFinish)
        }
        if reload {
            if !weapon.isReloading && weapon.ammoInMagazine < weapon.magazineSize {
                audio?.play(.reloadStart)
            }
            weapon.beginReload()
        }
        if trigger || triggerPressed {
            fire(aim: aim)
        }
        weapon.autoReloadIfEmpty()
        if weapon.justDryFired {
            events.append(FeedbackEvent(kind: .dryFire, text: nil, worldPosition: nil, value: 0))
            audio?.play(.dryFire)
        }

        // ---- Combo decay ------------------------------------------------------
        if combo > 0 {
            comboTimer += dt
            if comboTimer > 4.0 { combo = 0; comboTimer = 0 }
        }

        // ---- Director ---------------------------------------------------------
        let aliveFromEncounter = Session.threatsOwed(to: director.currentEncounterID,
                                                     among: zombies, tags: encounterTags)
        // The player's progress through the level is their position projected
        // onto the authored spine, so every encounter still fires exactly where
        // it was written for the rail version.
        let cmd = director.update(dt: dt, railDistance: field.player.railDistance,
                                  aliveFromEncounter: aliveFromEncounter) { [weak self] req in
            self?.spawn(req)
        }
        if let banner = director.bannerToShow {
            events.append(FeedbackEvent(kind: .banner, text: banner, worldPosition: nil, value: 0))
        }
        // `speedScale` and `gaze` are rail-era outputs: the player now controls
        // both their own pace and where they look, so the director only schedules
        // and seals.
        _ = cmd
        field.player.progressLimit = director.progressGate

        // Survivor lifecycle follows the encounter that owns them.
        updateSurvivor(dt: dt)

        // ---- World ------------------------------------------------------------
        field.update(dt: dt, input: move)
        field.settleWeaponLight(dt: dt)
        effects.update(dt: dt)

        // ---- Cast -------------------------------------------------------------
        let living = zombies.filter { $0.isThreat }
        for z in zombies {
            z.update(dt: dt, elapsed: elapsed, neighbours: living)
        }
        reapCorpses()
        updateGlobs(dt: dt)

        // ---- End conditions ---------------------------------------------------
        if health <= 0 {
            outcome = .lost
            audio?.play(.playerDown)
        } else if director.finished && field.player.atEnd {
            // Reaching the end with every encounter cleared is a win. The check
            // deliberately does NOT require the map to be empty: a straggler that
            // wandered off, fell behind, or lodged on geometry would otherwise
            // stall the run for ever, which a simulated playthrough caught as a
            // ten-minute timeout on level 1.
            endGrace += dt
            if !zombies.contains(where: { $0.isThreat }) || endGrace > 5 {
                outcome = .won
                audio?.play(.levelClear)
            }
        } else {
            endGrace = 0
        }
    }

    /// How many living enemies the given encounter is still owed.
    ///
    /// Scoped to one encounter ID on purpose. Counting "anything an encounter
    /// spawned" instead lets a hold that ended on its failsafe leave survivors
    /// behind that gate every encounter after it, so each one in turn has to
    /// wait out its own failsafe. Pulled out as a function so the rule can be
    /// tested directly rather than only through a full playthrough.
    static func threatsOwed(to encounterID: String?, among zombies: [Zombie],
                            tags: [ObjectIdentifier: String]) -> Int {
        guard let id = encounterID else { return 0 }
        return zombies.reduce(0) { acc, z in
            acc + ((z.isThreat && tags[ObjectIdentifier(z)] == id) ? 1 : 0)
        }
    }

    /// Consumes queued HUD feedback.
    func drainEvents() -> [FeedbackEvent] {
        let e = events
        events.removeAll(keepingCapacity: true)
        return e
    }

    // MARK: Shooting

    /// `aim` is in normalised device coordinates: (-1, -1) bottom-left to (1, 1) top-right.
    private func fire(aim: SIMD2<Float>) {
        guard weapon.tryFire() else { return }
        shots += 1
        effects.muzzleFlash()
        field.pulseWeaponLight(0.9)
        field.player.addRecoil(pitch: rng.float(2.6, 3.6), yaw: rng.float(-1.1, 1.1))
        field.player.addShake(0.10 * gameplay.screenShake)
        audio?.play(.gunshot)

        let origin = field.cameraNode.simdWorldPosition
        var dir = rayDirection(ndc: aim)
        dir = weapon.perturb(dir, rng: &rng)
        let maxRange: Float = 140

        // ---- Acid globs are shootable and take priority: they are the only
        // ---- target with a hard timer attached.
        if let idx = globs.firstIndex(where: { $0.intersects(origin: origin, direction: dir, maxDistance: maxRange) }) {
            let g = globs.remove(at: idx)
            effects.bloodBurst(at: g.position, direction: -dir, force: 0.8)
            effects.flashLight(at: g.position, color: NSColor.Pal.toxic, intensity: 900, life: 0.22)
            g.node.removeFromParentNode()
            registerHit(scoreValue: 120, headshot: false)
            audio?.play(.acidPop)
            return
        }

        // ---- Enemies ----------------------------------------------------------
        var bestZombie: Zombie?
        var bestPart = 0
        var bestT = Float.greatestFiniteMagnitude
        for z in zombies where z.isThreat {
            if let (idx, t) = z.body.raycast(origin: origin, direction: dir, maxDistance: maxRange), t < bestT {
                bestT = t; bestPart = idx; bestZombie = z
            }
        }

        // ---- Survivor -----------------------------------------------------------
        // Depth-ordered against the enemies: shooting an attacker that happens to
        // stand in front of a civilian must not punish the player for the civilian
        // behind it.
        if let s = survivor, s.alive,
           let hit = s.body.raycast(origin: origin, direction: dir, maxDistance: maxRange),
           hit.t < bestT {
            s.kill()
            survivorsLost += 1
            score = max(0, score - 2500)
            combo = 0
            health = max(1, health - 10)      // stings, but never the cause of death
            damageFlash = 1
            events.append(FeedbackEvent(kind: .survivorHurt, text: "CIVILIAN DOWN  -2500",
                                        worldPosition: s.body.chest.simdWorldPosition, value: -2500))
            audio?.play(.civilianDown)
            effects.bloodBurst(at: s.body.chest.simdWorldPosition, direction: -dir, force: 1.3)
            return
        }

        guard let target = bestZombie else {
            missedShot(origin: origin, direction: dir, maxRange: maxRange)
            return
        }

        // A shot that would pass through the world before reaching the enemy is a
        // miss — otherwise players can shoot through gravestones and walls.
        if let wall = worldHit(origin: origin, direction: dir, maxDistance: bestT) {
            effects.worldImpact(at: wall.point, normal: wall.normal)
            missRegistered()
            return
        }

        let zone = target.body.parts[bestPart].zone
        let point = origin + dir * bestT
        let result = target.applyDamage(weapon.damage, zone: zone, partIndex: bestPart,
                                        allowSever: gameplay.goreLevel > 0.3,
                                        impactDirection: dir)

        if result.absorbed && result.applied < 6 {
            // Bounced off armour: spark, no blood, and no combo credit.
            effects.worldImpact(at: point, normal: -dir)
            effects.flashLight(at: point, color: NSColor(rgb: 1.0, 0.85, 0.5), intensity: 500, life: 0.10)
            events.append(FeedbackEvent(kind: .armorPing, text: nil, worldPosition: point, value: 0))
            audio?.play(.armorPing)
            // Still counts as a hit for accuracy: the player did aim correctly.
            hits += 1
            return
        }

        if zone == .head {
            effects.headshotSpray(at: point, direction: -dir)
        } else {
            effects.bloodBurst(at: point, direction: -dir, force: 1.0)
        }
        if let severed = result.severed {
            effects.launchGib(severed, from: point, direction: dir)
        }

        if result.killed {
            kills += 1
            if zone == .head { headshots += 1 }
            let base = Float(target.stats.baseScore) * (zone == .head ? 2.0 : 1.0)
            registerHit(scoreValue: Int(base), headshot: zone == .head)
            events.append(FeedbackEvent(kind: .kill, text: zone == .head ? "HEADSHOT" : nil,
                                        worldPosition: point, value: Int(base * comboMultiplier)))
            audio?.play(zone == .head ? .headshot : .kill)
            effects.bloodDecal(at: target.position, groundY: field.built.groundHeight(target.position))
        } else {
            registerHit(scoreValue: 25, headshot: zone == .head)
            events.append(FeedbackEvent(kind: zone == .head ? .headshot : .hit, text: nil,
                                        worldPosition: point, value: 25))
            audio?.play(.fleshHit)
        }
    }

    private func missedShot(origin: SIMD3<Float>, direction: SIMD3<Float>, maxRange: Float) {
        if let wall = worldHit(origin: origin, direction: direction, maxDistance: maxRange) {
            effects.worldImpact(at: wall.point, normal: wall.normal)
            audio?.play(.ricochet)
        }
        missRegistered()
    }

    private func missRegistered() {
        combo = 0
        comboTimer = 0
    }

    private func registerHit(scoreValue: Int, headshot: Bool) {
        hits += 1
        combo += 1
        bestCombo = max(bestCombo, combo)
        comboTimer = 0
        score += Int(Float(scoreValue) * comboMultiplier * difficulty.scoreMultiplier)
    }

    var comboMultiplier: Float {
        1 + min(Float(combo) / 8, 4)      // 1x up to 5x
    }

    /// Ray against the static world, via SceneKit's own hit test. Used only to
    /// decide whether a shot was blocked, so precision matters more than speed.
    private func worldHit(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float)
        -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        let to = origin + direction * maxDistance
        let opts: [String: Any] = [
            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: false
        ]
        let results = field.built.root.hitTestWithSegment(from: origin.scn, to: to.scn, options: opts)
        guard let first = results.first else { return nil }
        return (first.worldCoordinates.simd, first.worldNormal.simd)
    }

    /// Camera ray through a normalised screen point.
    ///
    /// Computed from the camera's own parameters rather than `SCNView.unprojectPoint`
    /// so that shooting works identically in the headless harnesses, where there
    /// is no view to unproject against.
    func rayDirection(ndc: SIMD2<Float>) -> SIMD3<Float> {
        guard let cam = field.cameraNode.camera else { return field.cameraForward }
        let tanHalfV = tan(Float(cam.fieldOfView) * .pi / 180 / 2)
        let tanHalfH = tanHalfV * aspect
        let local = SIMD3<Float>(ndc.x * tanHalfH, ndc.y * tanHalfV, -1)
        return field.cameraNode.simdWorldOrientation.act(simd_normalize(local))
    }

    /// Viewport aspect ratio, set by the view layer each resize.
    var aspect: Float = 16.0 / 9.0

    // MARK: Spawning

    private func spawn(_ req: Director.SpawnRequest) {
        let d = req.def
        let world = field.player.worldPoint(railDistance: d.railDistance, lateral: d.lateral, height: d.height)
        var pos = world
        pos.y = field.built.groundHeight(world) + d.height
        let toPlayer = (field.player.eyePosition - pos).flat.normalizedSafe

        let z = Zombie(kind: d.kind, position: pos, facing: yawToward(toPlayer),
                       entrance: d.entrance, difficulty: difficulty,
                       seed: UInt64(rng.int(1, 1_000_000)))
        z.targetProvider = { [weak self] in
            guard let self else { return .zero }
            var p = self.field.player.eyePosition
            p.y = self.field.built.groundHeight(p)
            return p
        }
        z.groundSampler = { [weak self] p in
            self?.field.built.groundHeight(p) ?? 0
        }
        z.onStrike = { [weak self] zz in self?.playerStruck(by: zz) }
        z.onSpit = { [weak self] zz, target in self?.launchGlob(from: zz, toward: target) }
        z.onDeath = { [weak self] zz in
            self?.effects.registerCorpse(zz.node)
            self?.audio?.play(.zombieDeath)
        }
        field.dynamicRoot.addChildNode(z.node)
        zombies.append(z)
        if let id = req.encounterID { encounterTags[ObjectIdentifier(z)] = id }
        audio?.play(d.kind == .warden ? .bossRoar : .zombieAlert, at: pos)
    }

    /// Retires corpses that have finished falling, and writes off stragglers.
    private func reapCorpses() {
        let eye = field.player.eyePosition
        let forward = field.cameraForward.flat.normalizedSafe
        zombies.removeAll { z in
            if z.state == .dead && z.corpseAge > 0.4 {
                encounterTags.removeValue(forKey: ObjectIdentifier(z))
                // The node itself lives on under Effects' corpse budget.
                return true
            }
            // An ambush enemy the rail has left far behind can never catch up and
            // would otherwise trail the player for the rest of the level.
            // Stragglers that no encounter is waiting on: ambushes, and anything
            // left over from a hold that timed out.
            let owner = encounterTags[ObjectIdentifier(z)]
            if z.isThreat, owner == nil || owner != director.currentEncounterID {
                let delta = (z.position - eye).flat
                if simd_length(delta) > 34 && simd_dot(delta.normalizedSafe, forward) < -0.25 {
                    z.despawn()
                    encounterTags.removeValue(forKey: ObjectIdentifier(z))
                    return true
                }
            }
            return false
        }
    }

    // MARK: Player damage

    private func playerStruck(by z: Zombie) {
        guard damageImmunity <= 0, outcome == .running else { return }
        let dmg = z.stats.damage * difficulty.damageTaken
        applyPlayerDamage(dmg, from: z.position)
        audio?.play(.zombieAttack)
    }

    private func applyPlayerDamage(_ amount: Float, from source: SIMD3<Float>) {
        health = max(0, health - amount)
        damageImmunity = 0.85
        damageFlash = 1
        lastDamageDirection = (source - field.player.eyePosition).flat.normalizedSafe
        combo = 0
        field.player.addShake(0.85 * gameplay.screenShake)
        events.append(FeedbackEvent(kind: .playerHurt, text: nil, worldPosition: source, value: Int(amount)))
        audio?.play(.playerHurt)
    }

    /// Live acid projectiles, exposed so the simulated player can react to them.
    var incomingGlobs: [(position: SIMD3<Float>, distance: Float)] {
        globs.map { ($0.position, $0.position.flatDistance(to: field.player.eyePosition)) }
    }

    // MARK: Acid globs

    private func launchGlob(from z: Zombie, toward target: SIMD3<Float>) {
        let origin = z.body.head.simdWorldPosition
        var aim = field.player.eyePosition
        // Lead very slightly and add scatter, so a spitter is a threat but not a
        // guaranteed hit the player cannot answer.
        aim += SIMD3(rng.float(-0.35, 0.35), rng.float(-0.25, 0.25), rng.float(-0.35, 0.35))
        let glob = AcidGlob(origin: origin, target: aim, speed: 13.5)
        field.dynamicRoot.addChildNode(glob.node)
        globs.append(glob)
        audio?.play(.spit, at: origin)
        _ = target
    }

    private func updateGlobs(dt: Float) {
        var i = 0
        while i < globs.count {
            globs[i].update(dt: dt)
            let g = globs[i]
            let hitPlayer = g.position.flatDistance(to: field.player.eyePosition) < 0.55
                && abs(g.position.y - field.player.eyePosition.y) < 1.4
            if hitPlayer {
                applyPlayerDamage(ZombieKind.spitter.stats.damage * difficulty.damageTaken, from: g.position)
                effects.flashLight(at: g.position, color: NSColor.Pal.toxic, intensity: 800, life: 0.2)
                g.node.removeFromParentNode()
                globs.remove(at: i)
                continue
            }
            if g.age > 4.5 || g.position.y < field.built.groundHeight(g.position) - 0.2 {
                effects.worldImpact(at: g.position, normal: SIMD3(0, 1, 0))
                g.node.removeFromParentNode()
                globs.remove(at: i)
                continue
            }
            i += 1
        }
    }

    // MARK: Survivors

    private func updateSurvivor(dt: Float) {
        if let def = director.currentSurvivor, survivor == nil {
            let world = field.player.worldPoint(railDistance: def.railDistance, lateral: def.lateral)
            var pos = world
            pos.y = field.built.groundHeight(world)
            let s = SurvivorActor(position: pos, facing: yawToward((field.player.eyePosition - pos).flat), def: def)
            field.dynamicRoot.addChildNode(s.node)
            survivor = s
        }
        guard let s = survivor else { return }
        s.update(dt: dt, elapsed: elapsed)

        // Rescued once the encounter that owns them ends with them alive.
        if director.currentSurvivor == nil {
            if s.alive {
                survivorsSaved += 1
                score += Int(Float(s.def.rescueBonus) * difficulty.scoreMultiplier)
                health = min(maxHealth, health + s.def.healthReward)
                events.append(FeedbackEvent(kind: .pickup,
                                            text: "CIVILIAN RESCUED  +\(s.def.rescueBonus)",
                                            worldPosition: s.node.simdWorldPosition,
                                            value: s.def.rescueBonus))
                audio?.play(.rescue)
            }
            s.retire()
            survivor = nil
        }
    }

    // MARK: Results

    func makeResult() -> RunResult {
        var r = RunResult()
        r.won = outcome == .won
        r.score = score
        r.kills = kills
        r.totalThreats = def.totalThreats
        r.shots = shots
        r.hits = hits
        r.headshots = headshots
        r.survivorsSaved = survivorsSaved
        r.survivorsLost = survivorsLost
        r.bestCombo = bestCombo
        r.duration = elapsed
        r.healthRemaining = health
        r.healthMax = maxHealth
        if r.won {
            // End-of-level bonuses, folded into the final score.
            r.score += Int(r.accuracy * 5000)
            r.score += Int(r.healthFraction * 3000)
        }
        return r
    }

    func teardown() {
        for z in zombies { z.despawn() }
        zombies.removeAll()
        globs.forEach { $0.node.removeFromParentNode() }
        globs.removeAll()
        survivor?.retire()
        survivor = nil
        effects.clearCorpses()
    }
}

// MARK: - Acid projectile

final class AcidGlob {
    let node: SCNNode
    private(set) var position: SIMD3<Float>
    private var velocity: SIMD3<Float>
    private(set) var age: Float = 0
    private let radius: Float = 0.16

    init(origin: SIMD3<Float>, target: SIMD3<Float>, speed: Float) {
        position = origin
        // Lobbed with a slight arc, so it is visible and dodgeable-looking rather
        // than a hitscan line.
        let flat = (target - origin)
        let time = max(simd_length(flat) / speed, 0.25)
        velocity = flat / time + SIMD3(0, 0.5 * 9.0 * time, 0)

        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 10
        sphere.materials = [MaterialLibrary.shared.glow(NSColor.Pal.toxic, intensity: 2.0)]
        node = SCNNode(geometry: sphere)
        node.simdPosition = origin
        node.castsShadow = false

        let trail = SCNParticleSystem()
        trail.birthRate = 90
        trail.particleLifeSpan = 0.35
        trail.particleSize = 0.09
        trail.particleSizeVariation = 0.05
        trail.particleColor = NSColor(rgb: 0.42, 0.78, 0.24, 0.7)
        trail.particleImage = MaterialLibrary.softDot
        trail.blendMode = .additive
        trail.isLightingEnabled = false
        trail.particleVelocity = 0.3
        trail.spreadingAngle = 40
        trail.emitterShape = sphere
        node.addParticleSystem(trail)
    }

    func update(dt: Float) {
        age += dt
        velocity.y -= 9.0 * dt
        position += velocity * dt
        node.simdPosition = position
    }

    func intersects(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float) -> Bool {
        // Generous radius: hitting a fast-moving glob under pressure should feel
        // possible, not like threading a needle.
        let oc = origin - position
        let b = simd_dot(oc, direction)
        let c = simd_length_squared(oc) - (radius * 2.6) * (radius * 2.6)
        let disc = b * b - c
        guard disc >= 0 else { return false }
        let t = -b - sqrt(disc)
        return t >= 0 && t <= maxDistance
    }
}

// MARK: - Survivor

/// A civilian. Deliberately over-signalled — a bright marker, a pale palette and
/// no glowing eyes — because the penalty for shooting one is severe and the
/// player is making the decision in half a second, in the dark.
final class SurvivorActor {
    let node = SCNNode()
    let body: ZombieBody
    let def: SurvivorDef
    private(set) var alive = true
    private let marker: SCNNode

    init(position: SIMD3<Float>, facing: Float, def: SurvivorDef) {
        self.def = def
        body = ZombieBody(kind: .shambler, seed: 31337, civilian: true)
        node.addChildNode(body.root)
        node.simdPosition = position
        node.simdOrientation = simd_quatf(angle: facing, axis: SIMD3(0, 1, 0))

        // Floating marker: a soft light plus a glowing pip above the head.
        marker = SCNNode()
        let pip = SCNNode(geometry: SCNSphere(radius: 0.075))
        pip.geometry?.materials = [MaterialLibrary.shared.glow(NSColor(rgb: 0.45, 0.95, 1.0), intensity: 3.2)]
        marker.addChildNode(pip)
        let l = SCNLight()
        l.type = .omni
        l.color = NSColor(rgb: 0.5, 0.9, 1.0)
        l.intensity = 320
        l.attenuationEndDistance = 7
        l.castsShadow = false
        marker.light = l
        marker.simdPosition = SIMD3(0, 2.35, 0)
        node.addChildNode(marker)
    }

    func update(dt: Float, elapsed: Float) {
        guard alive else { return }
        // Cowering: crouched, arms up, shivering.
        let tremble = sin(elapsed * 9.5) * 0.02
        body.hips.simdPosition = SIMD3(0, body.hipsRestY - 0.26, 0)
        body.chest.simdOrientation = simd_quatf(angle: deg(26) + tremble, axis: SIMD3(1, 0, 0))
        body.neck.simdOrientation = simd_quatf(angle: deg(-14), axis: SIMD3(1, 0, 0))
        for (i, arm) in body.upperArm.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            arm.simdOrientation = simd_quatf(angle: deg(-142), axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: side * deg(26), axis: SIMD3(0, 0, 1))
            body.lowerArm[i].simdOrientation = simd_quatf(angle: deg(-72), axis: SIMD3(1, 0, 0))
        }
        for t in body.thigh { t.simdOrientation = simd_quatf(angle: deg(-52), axis: SIMD3(1, 0, 0)) }
        for s in body.shin { s.simdOrientation = simd_quatf(angle: deg(96), axis: SIMD3(1, 0, 0)) }
        marker.simdPosition = SIMD3(0, 2.15 + sin(elapsed * 2.2) * 0.07, 0)
    }

    func kill() {
        alive = false
        marker.removeFromParentNode()
        node.runAction(.sequence([
            .group([.fadeOut(duration: 1.4), .rotateBy(x: CGFloat.pi / 2.2, y: 0, z: 0, duration: 0.7)]),
            .removeFromParentNode()
        ]))
    }

    func retire() {
        node.runAction(.sequence([.fadeOut(duration: 0.6), .removeFromParentNode()]))
    }
}
