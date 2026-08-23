import Foundation
import SceneKit
import simd

/// First-person character controller.
///
/// Replaces the old rail camera. The player now walks the level themselves, but
/// the handheld character of the original is deliberately kept: the walk still
/// bobs in a figure-eight, the body still leans into a turn, standing still
/// still breathes, and being bitten still throws the aim. Free movement should
/// change who is steering, not make the camera feel like a floating tripod.
final class PlayerController {

    /// What the input layer hands over each frame.
    struct MoveInput {
        /// -1 back, +1 forward.
        var forward: Float = 0
        /// -1 left, +1 right.
        var strafe: Float = 0
        /// Mouse deltas in points, already scaled by sensitivity.
        var lookDeltaX: Float = 0
        var lookDeltaY: Float = 0
        var isSprinting = false
    }

    // World state
    /// Feet position. Eye height is added when posing the camera.
    private(set) var position: SIMD3<Float>
    private(set) var velocity: SIMD3<Float> = .zero
    private(set) var yaw: Float
    private(set) var pitch: Float = 0

    // Tuning
    private let eyeHeight: Float = 1.66
    private let walkSpeed: Float = 4.1
    /// Sprinting is an escape, not immunity: a Runner is faster than a walk but
    /// slower than a sprint, so fleeing costs the ground you were holding.
    private let sprintSpeed: Float = 5.6
    private let backSpeedScale: Float = 0.72
    private let strafeSpeedScale: Float = 0.86
    /// How quickly velocity reaches the commanded direction. High enough to feel
    /// crisp, low enough that a hard stop does not read as teleporting.
    private let accelRate: Float = 16
    private let decelRate: Float = 20
    private let maxPitch: Float = deg(85)

    /// Furthest rail distance the player may reach. Set by the director while an
    /// encounter is sealed; nil means the whole level is open.
    var progressLimit: Float?
    var swayAmount: Float = 1
    var shakeAmount: Float = 1
    var lookSensitivity: Float = 1

    // Level context
    private let projector: RailProjector
    private let collision: CollisionWorld
    private let groundAt: (SIMD3<Float>) -> Float
    /// Half-width of the walkable corridor around the rail.
    private let corridorHalfWidth: Float

    // Handheld motion
    private var walkPhase: Float = 0
    private var breathPhase: Float = 0
    private var driftTime: Float = 0
    private var leanRoll: Float = 0
    private var smoothedSpeed: Float = 0

    // Impulses
    private var shakeEnergy: Float = 0
    private var shakeTime: Float = 0
    private var recoilPitch: Float = 0
    private var recoilYaw: Float = 0
    private var recoilVelPitch: Float = 0
    private var recoilVelYaw: Float = 0

    /// Fires when a footfall lands, for audio.
    var onFootstep: (() -> Void)?
    private var lastBobSign: Float = 0

    private(set) var railDistance: Float = 0
    private(set) var railLateral: Float = 0

    init(projector: RailProjector, collision: CollisionWorld,
         groundAt: @escaping (SIMD3<Float>) -> Float, corridorHalfWidth: Float) {
        self.projector = projector
        self.collision = collision
        self.groundAt = groundAt
        self.corridorHalfWidth = corridorHalfWidth

        // Start at the beginning of the level's spine, facing down it.
        let start = projector.worldPoint(distance: 0.5, lateral: 0)
        position = SIMD3(start.x, groundAt(start), start.z)
        // The camera looks down local -Z, so the yaw convention differs from the
        // one actors use. See `cameraYaw` vs `yawToward`.
        yaw = cameraYaw(projector.forward(atDistance: 0.5))
        let p = projector.project(position)
        railDistance = p.distance
        railLateral = p.lateral
    }

    // MARK: Queries used by the rest of the game

    var eyePosition: SIMD3<Float> { SIMD3(position.x, position.y + eyeHeight, position.z) }
    /// Flattened facing, for AI and for movement.
    var forward: SIMD3<Float> {
        SIMD3(-sin(yaw), 0, -cos(yaw))
    }
    var right: SIMD3<Float> {
        SIMD3(cos(yaw), 0, -sin(yaw))
    }
    /// Full 3D look direction including pitch.
    var lookDirection: SIMD3<Float> {
        let cp = cos(pitch)
        return SIMD3(-sin(yaw) * cp, sin(pitch), -cos(yaw) * cp)
    }
    var progress: Float { projector.totalLength > 0 ? clamp01(railDistance / projector.totalLength) : 0 }
    var atEnd: Bool { railDistance >= projector.totalLength - 3.0 }
    var speed: Float { simd_length(velocity.flat) }

    /// Direction the player should head to make progress, for the objective marker.
    var objectiveDirection: SIMD3<Float> {
        projector.forward(atDistance: min(railDistance + 6, projector.totalLength))
    }

    func worldPoint(railDistance d: Float, lateral: Float, height: Float = 0) -> SIMD3<Float> {
        projector.worldPoint(distance: d, lateral: lateral, height: height)
    }

    // MARK: Impulses

    func addShake(_ strength: Float) {
        shakeEnergy = min(shakeEnergy + strength, 2.4)
        shakeTime = 0
    }

    func addRecoil(pitch p: Float, yaw y: Float) {
        recoilVelPitch += p
        recoilVelYaw += y
    }

    /// Used by the harnesses to place the player directly.
    func teleport(toRailDistance d: Float, lateral: Float = 0) {
        let p = projector.worldPoint(distance: d, lateral: lateral)
        position = SIMD3(p.x, groundAt(p), p.z)
        yaw = cameraYaw(projector.forward(atDistance: d))
        velocity = .zero
        let proj = projector.project(position)
        railDistance = proj.distance
        railLateral = proj.lateral
    }

    // MARK: Frame

    func update(dt: Float, input: MoveInput, cameraNode: SCNNode) {
        applyLook(input: input)
        applyMovement(dt: dt, input: input)
        poseCamera(dt: dt, cameraNode: cameraNode)
    }

    private func applyLook(input: MoveInput) {
        // Mouse deltas are in points; 0.0022 rad/point puts a 180° turn at about
        // 6 cm of mouse travel at the default sensitivity, which is close to the
        // usual desktop-shooter feel.
        let scale: Float = 0.0022 * lookSensitivity
        yaw -= input.lookDeltaX * scale
        pitch = clamp(pitch - input.lookDeltaY * scale, -maxPitch, maxPitch)
        // Keep yaw bounded so it never loses float precision on a long session.
        if yaw > .pi { yaw -= 2 * .pi }
        if yaw < -.pi { yaw += 2 * .pi }
    }

    private func applyMovement(dt: Float, input: MoveInput) {
        // Desired velocity in world space, built from the camera's flattened basis.
        var wish = forward * input.forward + right * input.strafe
        let wishLen = simd_length(wish)
        if wishLen > 1e-4 {
            wish /= wishLen
            var speedCap = input.isSprinting ? sprintSpeed : walkSpeed
            // Moving backwards or sideways is slower, which keeps facing the
            // threat the fastest way to travel.
            if input.forward < -0.1 { speedCap *= backSpeedScale }
            else if abs(input.strafe) > 0.1 && abs(input.forward) < 0.1 { speedCap *= strafeSpeedScale }
            wish *= min(wishLen, 1) * speedCap
        } else {
            wish = .zero
        }

        let rate = simd_length(wish) > simd_length(velocity) ? accelRate : decelRate
        velocity = damp(velocity, wish, rate, dt)
        if simd_length(velocity) < 0.02 { velocity = .zero }

        guard simd_length(velocity) > 1e-4 else { return }

        var target = position + velocity * dt
        target = clampToCorridor(target)
        let resolved = collision.resolve(from: position, to: target)
        // If collision ate the movement, drop the velocity too, or the player
        // keeps accelerating into a wall and shoots off when they clear it.
        if simd_distance(resolved, position) < simd_distance(target, position) * 0.35 {
            velocity *= 0.25
        }
        position = resolved
        position.y = groundAt(position)

        let proj = projector.project(position, hint: railDistance)
        railDistance = proj.distance
        railLateral = proj.lateral
    }

    /// Keeps the player inside the level's walkable band.
    ///
    /// Environments already have walls, but they have gaps, and the ground plane
    /// extends well past them. Without this the player can simply walk out of
    /// the level and into the void, which no amount of geometry collision
    /// reliably prevents.
    private func clampToCorridor(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let proj = projector.project(p, hint: railDistance)
        var out = p
        if abs(proj.lateral) > corridorHalfWidth {
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), proj.forward))
            let clampedLateral = corridorHalfWidth * (proj.lateral > 0 ? 1 : -1)
            let corrected = proj.point + right * clampedLateral
            out = SIMD3(corrected.x, p.y, corrected.z)
        }
        // A sealed encounter stops forward progress but leaves the arena free.
        if let limit = progressLimit, proj.distance > limit {
            let held = projector.worldPoint(distance: limit,
                                            lateral: clamp(proj.lateral, -corridorHalfWidth, corridorHalfWidth))
            out = SIMD3(held.x, out.y, held.z)
        }
        // Do not let the player back out through the level's entrance, or walk
        // past the end marker into unbuilt space.
        if proj.distance < 0.6 {
            let ahead = projector.worldPoint(distance: 0.6, lateral: clamp(proj.lateral, -corridorHalfWidth, corridorHalfWidth))
            out = SIMD3(ahead.x, out.y, ahead.z)
        } else if proj.distance > projector.totalLength - 0.6 {
            let back = projector.worldPoint(distance: projector.totalLength - 0.6,
                                            lateral: clamp(proj.lateral, -corridorHalfWidth, corridorHalfWidth))
            out = SIMD3(back.x, out.y, back.z)
        }
        return out
    }

    private func poseCamera(dt: Float, cameraNode: SCNNode) {
        let sp = simd_length(velocity.flat)
        smoothedSpeed = damp(smoothedSpeed, sp, 8, dt)
        let moving = clamp01(smoothedSpeed / walkSpeed)

        walkPhase += dt * (1.1 + smoothedSpeed * 0.42) * moving
        breathPhase += dt * 0.55
        driftTime += dt

        // Figure-eight walk bob: vertical at twice the lateral frequency, which
        // is what real footfalls produce.
        let bobV = sin(walkPhase * 2 * .pi * 2) * 0.038 * moving
        let bobH = sin(walkPhase * 2 * .pi) * 0.042 * moving
        let breathV = sin(breathPhase * 2 * .pi) * 0.011 * (1 - moving * 0.7)
        let driftH = (Noise.fbm(driftTime * 0.16, 4.2, octaves: 2, period: 8, seed: 11) - 0.5) * 0.035
        let driftV = (Noise.fbm(driftTime * 0.13, 9.7, octaves: 2, period: 8, seed: 22) - 0.5) * 0.03

        // Footstep on each bob trough.
        let bobSign: Float = sin(walkPhase * 2 * .pi * 2) >= 0 ? 1 : -1
        if moving > 0.25 && bobSign != lastBobSign && bobSign < 0 { onFootstep?() }
        lastBobSign = bobSign

        var eye = eyePosition
        eye += right * ((bobH + driftH) * swayAmount)
        eye.y += (bobV + breathV + driftV) * swayAmount

        // Lean into a strafe: a small roll that makes lateral movement legible.
        let lateralSpeed = simd_dot(velocity, right)
        let targetRoll = clamp(-lateralSpeed / max(walkSpeed, 0.1) * deg(2.4), -deg(3), deg(3)) * swayAmount
        leanRoll = damp(leanRoll, targetRoll, 6, dt)

        // Recoil: critically-damped spring back to zero.
        let stiffness: Float = 130, damping: Float = 17
        recoilVelPitch += (-stiffness * recoilPitch - damping * recoilVelPitch) * dt
        recoilVelYaw += (-stiffness * recoilYaw - damping * recoilVelYaw) * dt
        recoilPitch += recoilVelPitch * dt
        recoilYaw += recoilVelYaw * dt

        // Shake.
        shakeTime += dt
        shakeEnergy = max(0, shakeEnergy - dt * 1.8)
        let s = shakeEnergy * shakeEnergy * shakeAmount
        let sx = (Noise.fbm(shakeTime * 22, 0.5, octaves: 2, period: 16, seed: 91) - 0.5) * 2
        let sy = (Noise.fbm(shakeTime * 20, 5.5, octaves: 2, period: 16, seed: 92) - 0.5) * 2
        let sz = (Noise.fbm(shakeTime * 17, 9.5, octaves: 2, period: 16, seed: 93) - 0.5) * 2

        let finalYaw = yaw + recoilYaw + sx * deg(2.4) * s
        let finalPitch = clamp(pitch + recoilPitch + sy * deg(2.0) * s, -maxPitch - deg(6), maxPitch + deg(6))
        let finalRoll = leanRoll + sz * deg(1.8) * s

        cameraNode.simdPosition = eye + SIMD3(0, sy * 0.025 * s, 0)
        cameraNode.simdOrientation =
            simd_quatf(angle: finalYaw, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: finalPitch, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: finalRoll, axis: SIMD3(0, 0, 1))
    }
}
