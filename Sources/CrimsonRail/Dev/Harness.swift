import Foundation
import SceneKit
import AppKit
import simd

/// Command-line entry points used to develop and verify the game without a
/// human at the keyboard. Every one of these runs headless.
enum Harness {

    struct Args {
        private var raw: [String]
        init(_ argv: [String]) { raw = argv }

        func has(_ flag: String) -> Bool { raw.contains(flag) }
        func string(_ flag: String, _ fallback: String? = nil) -> String? {
            guard let i = raw.firstIndex(of: flag), i + 1 < raw.count else { return fallback }
            return raw[i + 1]
        }
        func int(_ flag: String, _ fallback: Int) -> Int {
            guard let s = string(flag), let v = Int(s) else { return fallback }
            return v
        }
        func float(_ flag: String, _ fallback: Float) -> Float {
            guard let s = string(flag), let v = Float(s) else { return fallback }
            return v
        }
    }

    static func out(_ s: String) {
        FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    }

    // MARK: --shot

    /// Renders one level at a chosen point on its rail.
    ///
    ///   --shot out.png [--level 1] [--at 12] [--width 1600] [--height 1000]
    ///                  [--quality high] [--scenario play|wide|top]
    /// Renders one or more bodies in an empty studio scene, driven for a chosen
    /// number of seconds so a real animation state can be inspected.
    ///
    ///   --solo out.png [--kind shambler|all] [--state approach|windup|strike|stagger|emerging]
    ///                  [--time 1.5] [--width 600] [--height 800]
    static func solo(_ args: Args) -> Int32 {
        let path = args.string("--solo") ?? "solo.png"
        let kindName = args.string("--kind", "shambler") ?? "shambler"
        let stateName = args.string("--state", "approach") ?? "approach"
        let time = args.float("--time", 1.2)
        MaterialLibrary.shared.configure(quality: .forPreset(.ultra))

        let kinds: [ZombieKind] = kindName == "all"
            ? ZombieKind.allCases
            : [ZombieKind(rawValue: kindName) ?? .shambler]

        let scene = SCNScene()
        scene.background.contents = NSColor(rgb: 0.035, 0.038, 0.05)

        // A studio rig: key, fill and a rim from behind, so form reads clearly.
        for (dir, intensity, colour) in [
            (SIMD3<Float>(-0.5, -0.55, -0.75), Float(2600), NSColor(rgb: 1.0, 0.95, 0.88)),
            (SIMD3<Float>(0.8, -0.25, -0.45), Float(700), NSColor(rgb: 0.55, 0.65, 0.9)),
            (SIMD3<Float>(0.1, -0.2, 0.95), Float(1400), NSColor(rgb: 0.7, 0.8, 1.0)),
        ] {
            let n = SCNNode()
            let l = SCNLight(); l.type = .directional; l.intensity = CGFloat(intensity)
            l.color = colour; l.castsShadow = false
            n.light = l
            n.simdOrientation = lookRotation(forward: simd_normalize(dir))
            scene.rootNode.addChildNode(n)
        }
        let ambNode = SCNNode()
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 260
        amb.color = NSColor(rgb: 0.4, 0.45, 0.6)
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        // Ground, so the feet have something to stand on and cast contact onto.
        let floor = Props.ground(size: 40, kind: .dirt, tiling: 0.5, heightScale: 0, divisions: 2, seed: 5)
        scene.rootNode.addChildNode(floor)

        let spacing: Float = 1.8
        var cast: [Zombie] = []
        for (i, k) in kinds.enumerated() {
            let x = (Float(i) - Float(kinds.count - 1) / 2) * spacing
            let z = Zombie(kind: k, position: SIMD3(x, 0, 0), facing: 0,
                           entrance: .lurch, difficulty: .agent, seed: UInt64(700 + i * 131))
            // Target off to one side so the cast is seen at three-quarters; arms
            // reaching straight down the lens tell you nothing about the pose.
            let aim = deg(args.float("--facing", 38))
            z.targetProvider = { SIMD3(x + sin(aim) * 12, 0, cos(aim) * 12) }
            scene.rootNode.addChildNode(z.node)
            cast.append(z)
        }

        // Drive to the requested state, then hold it by re-entering each frame.
        // Drive the animation, but keep each subject on its mark: a walking
        // zombie drifts out of frame during the run-up to the pose.
        let marks = cast.map { $0.position }
        let dt: Float = 1.0 / 120.0
        var t: Float = 0
        while t < time {
            for (i, z) in cast.enumerated() {
                z.update(dt: dt, elapsed: t, neighbours: cast)
                z.node.simdPosition = marks[i]
            }
            t += dt
        }
        if stateName != "approach" && stateName != "emerging" {
            for z in cast { z.debugForceState(stateName) }
            // Let the forced state play a little way in so the pose is expressive.
            var u: Float = 0
            let hold = args.float("--hold", 0.16)
            while u < hold {
                for (i, z) in cast.enumerated() {
                    z.update(dt: dt, elapsed: t + u, neighbours: cast)
                    z.node.simdPosition = marks[i]
                }
                u += dt
            }
        }

        // Frame the cast: centre on the group and pull back far enough that the
        // tallest archetype fits with a little headroom.
        let cam = SCNNode()
        let c = SCNCamera(); c.projectionDirection = .vertical; c.fieldOfView = 42
        c.zNear = 0.05; c.zFar = 60
        c.wantsHDR = true; c.exposureOffset = 0.2
        cam.camera = c

        let tallest = (cast.map { $0.body.standHeight }.max() ?? 1.9)
        let span = Float(max(kinds.count - 1, 0)) * spacing
        let halfV = tan(deg(21))
        let aspect = Float(args.int("--width", 640)) / Float(args.int("--height", 760))
        // Distance needed to fit both the height and the width of the line-up.
        let forHeight = (tallest * 0.62) / halfV
        let forWidth = (span * 0.62) / (halfV * aspect)
        let dist = args.float("--dist", max(forHeight, forWidth) + 1.6)
        let eyeY = tallest * 0.52
        cam.simdPosition = SIMD3(0, eyeY, dist)
        cam.simdOrientation = lookRotation(forward: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(cam)

        var opts = OffscreenRenderer.Options()
        opts.width = args.int("--width", 640); opts.height = args.int("--height", 760)
        opts.warmupFrames = 3
        guard let img = OffscreenRenderer.render(scene: scene, pointOfView: cam, options: opts) else { return 1 }
        OffscreenRenderer.writePNG(img, to: path)
        let s = OffscreenRenderer.stats(img)
        out(String(format: "wrote %@  kinds=%d state=%@  meanLuma=%.1f", path, kinds.count, stateName, s.meanLuma))
        return 0
    }

    static func shot(_ args: Args) -> Int32 {
        let path = args.string("--shot") ?? "shot.png"
        let levelIndex = max(0, args.int("--level", 1) - 1)
        let at = args.float("--at", 12)
        let width = args.int("--width", 1440)
        let height = args.int("--height", 900)
        let scenario = args.string("--scenario", "play") ?? "play"
        let presetName = args.string("--quality", "high") ?? "high"
        let preset = QualityPreset(rawValue: presetName) ?? .high

        var quality = GraphicsSettings.forPreset(preset)
        // Offscreen rendering has no backing-store scale to fight with.
        quality.renderScale = 1

        let def = LevelCatalog.level(levelIndex)
        let t0 = Date()
        let field = Playfield(def: def, quality: quality, gameplay: GameplaySettings())
        let buildMs = Date().timeIntervalSince(t0) * 1000

        // Advance the rail to the requested point with a real update loop, so the
        // camera's smoothing, bob and flicker states are where they'd actually be.
        // Place the player at the requested point on the level's spine, then let
        // a few frames of the real update loop settle the camera's smoothing,
        // bob and flicker state.
        let dt: Float = 1.0 / 60.0
        field.player.teleport(toRailDistance: at)
        for _ in 0..<8 { field.update(dt: dt) }

        // Optional cast preview: one of each archetype lined up ahead of the
        // camera, held in a chosen animation state.
        var previewCast: [Zombie] = []
        if scenario.hasPrefix("cast") || scenario == "zombies" {
            let kinds: [ZombieKind] = [.shambler, .runner, .crawler, .spitter, .brute, .warden]
            let f = field.player.forward
            let r = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), f))
            let base = field.player.eyePosition
            for (i, k) in kinds.enumerated() {
                let lateral = (Float(i) - Float(kinds.count - 1) / 2) * 1.9
                var p: SIMD3<Float> = base + f * 7.5 + r * lateral
                p.y = field.built.groundHeight(p)
                let z = Zombie(kind: k, position: p, facing: yawToward(-f),
                               entrance: .lurch, difficulty: .agent, seed: UInt64(4000 + i * 37))
                z.targetProvider = { [weak field] in field?.player.eyePosition ?? .zero }
                z.groundSampler = { pos in Environments.groundHeight(pos, seed: def.seed) }
                if ProcessInfo.processInfo.environment["CR_ROOTADD"] != nil {
                    field.scene.rootNode.addChildNode(z.node)
                } else {
                    field.dynamicRoot.addChildNode(z.node)
                }
                previewCast.append(z)
                if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil {
                    let bb = z.node.boundingBox
                    out(String(format: "  %@ pos=(%.2f %.2f %.2f) children=%d bbox=(%.2f..%.2f y)",
                               k.rawValue, p.x, p.y, p.z, z.node.childNodes.count,
                               Float(bb.min.y), Float(bb.max.y)))
                }
            }
        }

        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil {
            let e = field.player.eyePosition, f2 = field.player.forward
            out(String(format: "  eye=(%.2f %.2f %.2f) fwd=(%.2f %.2f %.2f)", e.x, e.y, e.z, f2.x, f2.y, f2.z))
        }

        var pov = field.cameraNode
        switch scenario {
        case "castclose":
            let observer = SCNNode()
            let c = SCNCamera(); c.projectionDirection = .vertical; c.fieldOfView = 45
            c.zNear = 0.05; c.zFar = 60
            observer.camera = c
            if let target = previewCast.first(where: { $0.kind == .spitter }) {
                let t = target.node.simdPosition
                observer.simdPosition = t + SIMD3(0, 1.2, 0) - field.player.forward * 4.0
                observer.simdOrientation = lookRotation(forward: field.player.forward)
            }
            field.scene.rootNode.addChildNode(observer)
            pov = observer
        case "zombies", "cast":
            // Step back and raise the eye a little so the whole line-up frames.
            let observer = SCNNode()
            observer.camera = field.cameraNode.camera
            observer.simdPosition = field.player.eyePosition - field.player.forward * 1.5 + SIMD3(0, 0.3, 0)
            observer.simdOrientation = lookRotation(forward: field.player.forward)
            field.scene.rootNode.addChildNode(observer)
            pov = observer
        case "wide":
            // Pull back and up for a composition check of the whole set.
            let observer = SCNNode()
            observer.camera = field.cameraNode.camera
            let p = field.player.eyePosition
            observer.simdPosition = p - field.player.forward * 14 + SIMD3(0, 9, 0)
            observer.simdOrientation = lookRotation(forward: simd_normalize(field.player.forward + SIMD3(0, -0.45, 0)))
            field.scene.rootNode.addChildNode(observer)
            pov = observer
        case "top":
            let observer = SCNNode()
            let cam = SCNCamera()
            cam.projectionDirection = .vertical
            cam.fieldOfView = 60
            cam.zNear = 1; cam.zFar = 400
            observer.camera = cam
            let p = field.player.eyePosition
            observer.simdPosition = p + SIMD3(0, 55, 0)
            observer.simdOrientation = lookRotation(forward: SIMD3(0, -1, 0))
            field.scene.rootNode.addChildNode(observer)
            pov = observer
        default:
            break
        }

        var opts = OffscreenRenderer.Options()
        opts.width = width; opts.height = height
        // The sky follows the camera, and particle systems need time on the clock.
        let renderStart = Date()
        guard let img = OffscreenRenderer.render(scene: field.scene, pointOfView: pov, options: opts,
                                                 onWarmupFrame: { frame, step in
                                                     field.update(dt: Float(step))
                                                     for z in previewCast {
                                                         z.update(dt: Float(step),
                                                                  elapsed: Float(frame) * Float(step),
                                                                  neighbours: [])
                                                     }
                                                 })
        else {
            out("render failed"); return 1
        }
        if ProcessInfo.processInfo.environment["CR_VERBOSE"] != nil {
            for z in previewCast {
                let w = z.body.chest.simdWorldPosition
                let inScene = z.node.parent != nil
                out(String(format: "  post-render %@ chestWorld=(%.2f %.2f %.2f) inScene=%@ hidden=%@ opacity=%.2f",
                           z.kind.rawValue, w.x, w.y, w.z, inScene ? "Y" : "N",
                           z.node.isHidden ? "Y" : "N", Float(z.node.opacity)))
            }
        }
        let renderMs = Date().timeIntervalSince(renderStart) * 1000
        guard OffscreenRenderer.writePNG(img, to: path) else { return 1 }

        let s = OffscreenRenderer.stats(img)
        out(String(format: "wrote %@  (%dx%d)  level=%d '%@'  at=%.1fm/%.1fm  build=%.0fms render=%.0fms",
                   path, width, height, levelIndex + 1, def.name,
                   field.player.railDistance, field.built.spline.totalLength, buildMs, renderMs))
        out(String(format: "  meanLuma=%.1f  litFraction=%.3f", s.meanLuma, s.litFraction))
        if s.meanLuma < 2 {
            out("  WARNING: frame is essentially black")
        }
        return 0
    }
}

