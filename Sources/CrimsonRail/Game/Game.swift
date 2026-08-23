import Foundation
import AppKit
import SceneKit
import SpriteKit
import simd

/// Top-level coordinator: owns settings, progress, the active run, the HUD and
/// the menu layer, and routes input to whichever is in charge.
final class Game: NSObject {
    static private(set) var shared: Game!

    enum Mode: Equatable {
        case mainMenu
        case levelSelect
        case settings
        case briefing(level: Int)
        case playing
        case paused
        case results
        case credits

        var isMenu: Bool { self != .playing }
    }

    let view: GameView
    var settings: Settings
    var save: SaveData
    private(set) var mode: Mode = .mainMenu

    private(set) var session: Session?
    private(set) var playingLevelIndex: Int?
    let audio: AudioDirector
    let hud: HUD
    let menuModel: MenuModel

    private var lastFrameTime: TimeInterval = 0
    private var focusObservers: [NSObjectProtocol] = []
    private var pendingSettingsSave: DispatchWorkItem?
    // CR_FPS=1 prints the live frame rate once a second. The offscreen --perf
    // harness serialises CPU and GPU with a blocking wait per frame, so it
    // understates the real pipelined cost; this measures what the player gets.
    private let logsFPS = ProcessInfo.processInfo.environment["CR_FPS"] != nil
    private var fpsAccum: Double = 0
    private var fpsFrames = 0
    private var fpsWorst: Double = 0
    /// Fires the audio bank build off the first frame, so the window appears
    /// immediately instead of after a second of silent synthesis.
    private var audioStarted = false

    init(view: GameView) {
        self.view = view
        let loaded = Store.loadSettings()
        self.settings = loaded
        self.save = SaveData.load()
        self.audio = AudioDirector(settings: loaded.audio)
        self.hud = HUD(size: view.bounds.size)
        self.menuModel = MenuModel(settings: loaded, save: save)
        super.init()
        Game.shared = self
        menuModel.game = self
        hud.configure(gameplay: loaded.gameplay)
        view.inputDelegate = self
        view.delegate = self
        view.rendersContinuously = true
        view.isPlaying = true
        applyViewSettings()
        observeFocusLoss()
    }

    /// Pauses, and hands the mouse back, whenever the game stops being frontmost.
    ///
    /// This is not a nicety. Mouse look calls
    /// `CGAssociateMouseAndMouseCursorPosition(0)`, which decouples the pointer
    /// from the hardware mouse **for the whole system**. Command-Tabbing away
    /// mid-mission previously left it that way: the player's cursor stopped
    /// tracking in every other application until they came back and paused.
    /// Held movement keys are stranded by the same route, because the `keyUp`
    /// is delivered to whichever app took focus.
    private func observeFocusLoss() {
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                // A different window of our own app losing key status is not our
                // problem; only react when it is the game's window (or the app).
                if let window = note.object as? NSWindow, window !== self.view.window { return }
                if self.mode == .playing { self.setMode(.paused) }
                self.view.releaseCaptureIfNeeded()
            })
        }
    }

    deinit {
        for o in focusObservers { NotificationCenter.default.removeObserver(o) }
    }

    /// Belt and braces: never leave the pointer decoupled at exit.
    func releaseInputCapture() {
        view.releaseCaptureIfNeeded()
    }

    // MARK: Settings

    func applyViewSettings() {
        let g = settings.graphics
        view.antialiasingMode = {
            switch g.antialiasing {
            case 4: return .multisampling4X
            case 2: return .multisampling2X
            default: return SCNAntialiasingMode.none
            }
        }()
        if let layer = view.layer {
            let backing = view.window?.backingScaleFactor ?? 2.0
            layer.contentsScale = backing * CGFloat(g.renderScale)
        }
        view.preferredFramesPerSecond = g.frameRateCap > 0 ? g.frameRateCap : 0
        hud.size = view.bounds.size
        session?.aspect = Float(max(view.bounds.width, 1) / max(view.bounds.height, 1))
    }

    func updateSettings(_ new: Settings) {
        let old = settings
        settings = new

        // Persisting is debounced. A SwiftUI Slider calls its setter on every
        // tick of a drag, so writing here directly meant a JSON encode and an
        // atomic file replace dozens of times a second while the player nudged
        // a slider.
        scheduleSettingsSave()

        // Both of these are expensive and neither changes for most settings:
        // `applyViewSettings` resizes the Metal backing store via
        // `contentsScale`, and `configure` rebuilds the crosshair geometry.
        if new.graphics.renderScale != old.graphics.renderScale
            || new.graphics.antialiasing != old.graphics.antialiasing
            || new.graphics.frameRateCap != old.graphics.frameRateCap {
            applyViewSettings()
        }
        audio.update(settings: new.audio)
        if new.gameplay.crosshair != old.gameplay.crosshair
            || new.gameplay.crosshairScale != old.gameplay.crosshairScale
            || new.gameplay.showDamageNumbers != old.gameplay.showDamageNumbers {
            hud.configure(gameplay: new.gameplay)
        }
        session?.field.gameplay = new.gameplay
        session?.field.player.swayAmount = new.gameplay.cameraSway
        session?.field.player.shakeAmount = new.gameplay.screenShake
        session?.field.player.lookSensitivity = new.gameplay.lookSensitivity
        session?.effects.setQuality(session?.field.quality ?? new.graphics, gore: new.gameplay.goreLevel)
        menuModel.settings = new
    }

    /// Coalesces a burst of settings changes into a single write.
    private func scheduleSettingsSave() {
        pendingSettingsSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Store.save(self.settings)
            self.pendingSettingsSave = nil
        }
        pendingSettingsSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes immediately, for the points where losing the change would be worse
    /// than the cost of the write: leaving the settings screen, and quitting.
    func flushSettings() {
        pendingSettingsSave?.cancel()
        pendingSettingsSave = nil
        Store.save(settings)
    }

    // MARK: Mode

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        // Leaving the settings screen is the natural commit point.
        if mode == .settings && m != .settings { flushSettings() }
        mode = m
        view.capturesAim = (m == .playing)
        // The SpriteKit HUD is only meaningful in play and pause.
        hud.isHidden = !(m == .playing || m == .paused)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuModel.mode = m
            self.menuModel.save = self.save
            UIRoot.setMenuVisible(m.isMenu)
        }
        if m != .playing && m != .paused && m != .settings {
            audio.setThreatLevel(0)
        }
    }

    // MARK: Level lifecycle

    func startLevel(_ index: Int) {
        session?.teardown()
        let def = LevelCatalog.level(index)
        let s = Session(def: def, settings: settings)
        s.audio = audio
        s.aspect = Float(max(view.bounds.width, 1) / max(view.bounds.height, 1))
        session = s
        playingLevelIndex = index
        view.scene = s.field.scene
        view.pointOfView = s.field.cameraNode
        audio.setAmbience(s.field.built.ambience)
        audio.startMusic()
        setMode(.playing)
    }

    func restartLevel() {
        guard let i = playingLevelIndex else { abandonRun(); return }
        startLevel(i)
    }

    func abandonRun() {
        session?.teardown()
        session = nil
        playingLevelIndex = nil
        view.scene = nil
        audio.stopMusic()
        setMode(.mainMenu)
    }

    private func finishRun() {
        guard let s = session, let index = playingLevelIndex else { return }
        let result = s.makeResult()
        save.record(levelIndex: index, result: result)
        save.persist()
        menuModel.lastResult = result
        menuModel.lastLevelIndex = index
        menuModel.save = save
        setMode(.results)
    }
}

// MARK: - Frame loop

extension Game: SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if lastFrameTime == 0 { lastFrameTime = time }
        var dt = Float(time - lastFrameTime)
        lastFrameTime = time
        // Clamp so a hitch, a window drag or a wake from sleep cannot teleport the
        // camera or skip an encounter trigger.
        dt = clamp(dt, 0, 0.1)

        if !audioStarted {
            audioStarted = true
            // Off the render thread: synthesising the bank takes a few hundred ms.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.audio.start()
                self.audio.update(settings: self.settings.audio)
            }
        }

        if logsFPS {
            fpsAccum += Double(dt)
            fpsFrames += 1
            fpsWorst = max(fpsWorst, Double(dt))
            if fpsAccum >= 1.0 {
                let avg = fpsAccum / Double(fpsFrames)
                FileHandle.standardError.write(String(
                    format: "fps %.0f  (avg %.2f ms, worst %.2f ms)  mode=%@\n",
                    1 / avg, avg * 1000, fpsWorst * 1000, String(describing: mode))
                    .data(using: .utf8)!)
                fpsAccum = 0; fpsFrames = 0; fpsWorst = 0
            }
        }

        let input = view.consumeEdges()
        step(dt: dt, input: input)
    }

    private func step(dt: Float, input: InputState) {
        switch mode {
        case .playing:
            guard let s = session else { return }
            if input.pausePressed {
                setMode(.paused)
                audio.play(.uiBack)
                return
            }
            // Mouse-look puts the crosshair at the centre of the view, so the
            // aim ray is straight down the camera's forward axis.
            let ndc = SIMD2<Float>(0, 0)
            let invert = settings.gameplay.invertReloadButton
            let fireHeld = invert ? false : input.triggerDown
            let firePressed = invert ? input.reloadPressed : input.triggerPressed
            let reloadPressed = invert ? input.triggerPressed : input.reloadPressed

            var move = PlayerController.MoveInput()
            move.forward = input.moveForward
            move.strafe = input.moveStrafe
            move.isSprinting = input.sprinting
            move.lookDeltaX = input.lookDeltaX
            move.lookDeltaY = settings.gameplay.invertLookY ? -input.lookDeltaY : input.lookDeltaY

            s.update(dt: dt, aim: ndc, trigger: fireHeld,
                     triggerPressed: firePressed, reload: reloadPressed, move: move)

            audio.setListener(position: s.field.cameraPosition,
                              forward: s.field.cameraForward,
                              right: s.field.cameraNode.simdWorldOrientation.act(SIMD3(1, 0, 0)))
            audio.setThreatLevel(threatLevel(of: s))
            audio.updateMusic(dt: dt)

            drainFeedback(from: s, aim: input.aim)
            hud.update(dt: dt, snapshot: snapshot(from: s, aim: input.aim))

            if s.outcome != .running { finishRun() }

        case .paused:
            if input.pausePressed {
                setMode(.playing)
                audio.play(.uiSelect)
            }
            audio.updateMusic(dt: dt)

        default:
            // Menus still tick the scene behind them, so a loaded level stays alive.
            session?.field.update(dt: dt)
            audio.updateMusic(dt: dt)
        }
    }

    /// Horizontal offset of the "this way" marker, -1 (hard left) to 1 (hard
    /// right), or nil when the exit is roughly ahead. With free movement the
    /// player needs to be told where the level continues; without it they wander.
    private func objectiveMarkerX(for s: Session) -> Float? {
        let toExit = s.field.player.objectiveDirection.flat.normalizedSafe
        let fwd = s.field.player.forward.flat.normalizedSafe
        let right = s.field.player.right.flat.normalizedSafe
        let along = simd_dot(toExit, fwd)
        let side = simd_dot(toExit, right)
        // Nothing to show when it is already comfortably in front.
        if along > 0.86 { return nil }
        // Behind the player: pin to whichever edge is the shorter way round.
        if along < 0 { return side >= 0 ? 1 : -1 }
        return clamp(side / 0.86, -1, 1)
    }

    private func threatLevel(of s: Session) -> Float {
        let alive = s.zombies.filter { $0.isThreat }.count
        let close = s.zombies.filter { $0.isThreat && $0.distanceToTarget < 9 }.count
        let health = 1 - clamp01(s.health / s.maxHealth)
        return clamp01(Float(alive) / 7 * 0.55 + Float(close) / 3 * 0.30 + health * 0.25)
    }

    private func snapshot(from s: Session, aim: CGPoint) -> HUD.Snapshot {
        HUD.Snapshot(
            aim: aim,
            health: s.health,
            maxHealth: s.maxHealth,
            ammo: s.weapon.ammoInMagazine,
            magazineSize: s.weapon.magazineSize,
            reloading: s.weapon.isReloading,
            reloadProgress: s.weapon.reloadProgress,
            score: s.score,
            combo: s.combo,
            comboMultiplier: s.comboMultiplier,
            accuracy: s.shots > 0 ? Float(s.hits) / Float(s.shots) : 1,
            levelName: s.def.name,
            progress: s.field.player.progress,
            threatsRemaining: s.director.encounterThreatsRemaining,
            damageFlash: s.damageFlash,
            isHolding: s.director.isSealed,
            objectiveScreenX: objectiveMarkerX(for: s))
    }

    /// Turns the session's queued gameplay events into HUD feedback.
    private func drainFeedback(from s: Session, aim: CGPoint) {
        for e in s.drainEvents() {
            switch e.kind {
            case .hit:
                hud.showHitMarker(kill: false)
            case .headshot:
                hud.showHitMarker(kill: false)
                if let p = e.worldPosition, let sp = project(p, session: s) {
                    hud.floatText("HEAD", at: sp, color: NSColor.Pal.hazard, size: 13)
                }
            case .kill:
                hud.showHitMarker(kill: true)
                if let p = e.worldPosition, let sp = project(p, session: s) {
                    let label = e.text.map { "\($0)  +\(e.value)" } ?? "+\(e.value)"
                    hud.floatText(label, at: sp,
                                  color: e.text != nil ? NSColor.Pal.hazard : NSColor.Pal.ui,
                                  size: e.text != nil ? 17 : 15)
                }
            case .armorPing:
                hud.showHitMarker(kill: false)
                if let p = e.worldPosition, let sp = project(p, session: s) {
                    hud.floatText("ARMOURED", at: sp, color: NSColor(rgb: 0.75, 0.75, 0.8), size: 12)
                }
            case .playerHurt:
                // Bearing of the attacker relative to where the player is looking.
                let f = s.field.cameraForward
                let r = s.field.cameraNode.simdWorldOrientation.act(SIMD3(1, 0, 0))
                let d = s.lastDamageDirection
                hud.showDamageDirection(atan2(simd_dot(d, r), simd_dot(d, f)))
            case .survivorHurt, .pickup:
                if let t = e.text { hud.showBanner(t) }
            case .banner:
                if let t = e.text { hud.showBanner(t) }
            case .reloadDone, .dryFire:
                break
            }
        }
    }

    /// World point -> HUD screen point, or nil when it is behind the camera.
    private func project(_ world: SIMD3<Float>, session s: Session) -> CGPoint? {
        guard let cam = s.field.cameraNode.camera else { return nil }
        let inv = simd_inverse(s.field.cameraNode.simdWorldTransform)
        let v4 = inv * SIMD4(world, 1)
        let v = SIMD3(v4.x, v4.y, v4.z)
        guard v.z < -0.05 else { return nil }
        let tanHalfV = tan(Float(cam.fieldOfView) * .pi / 180 / 2)
        let tanHalfH = tanHalfV * s.aspect
        let ndcX = (v.x / -v.z) / tanHalfH
        let ndcY = (v.y / -v.z) / tanHalfV
        guard abs(ndcX) < 1.4, abs(ndcY) < 1.4 else { return nil }
        let size = view.bounds.size
        return CGPoint(x: CGFloat((ndcX + 1) / 2) * size.width,
                       y: CGFloat((ndcY + 1) / 2) * size.height)
    }
}

// MARK: - Input

extension Game: GameViewDelegate {
    func gameView(_ view: GameView, didUpdateInput input: InputState) {}

    func gameViewDidResize(_ view: GameView) {
        applyViewSettings()
    }

    func gameViewKeyDown(_ view: GameView, key: String, keyCode: UInt16,
                         modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.command) { return false }
        switch key {
        case "f":
            view.window?.toggleFullScreen(nil)
            return true
        default:
            return false
        }
    }
}
