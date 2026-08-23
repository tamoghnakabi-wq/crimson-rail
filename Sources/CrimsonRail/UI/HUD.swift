import Foundation
import SpriteKit
import AppKit
import simd

/// In-game overlay, drawn as a SpriteKit scene attached to the `SCNView`.
///
/// The crosshair in particular has to be here rather than in SwiftUI: an
/// overlay scene is updated inside SceneKit's own render loop, so the reticle
/// lands on the same frame as the world behind it. A separately-composited view
/// trails the pointer by a frame or two, which on a light-gun-style shooter is
/// immediately obvious.
final class HUD: SKScene {
    // Crosshair
    private let crosshair = SKNode()
    private var crosshairArms: [SKShapeNode] = []
    private var crosshairDot: SKShapeNode!
    private let hitMarker = SKNode()
    private var hitMarkerArms: [SKShapeNode] = []

    // Status
    private var healthBar: SKShapeNode!
    private var healthFill: SKShapeNode!
    private var healthText: SKLabelNode!
    private var ammoPips: [SKShapeNode] = []
    private var reloadArc: SKShapeNode!
    private var reloadLabel: SKLabelNode!
    private var scoreLabel: SKLabelNode!
    private var comboLabel: SKLabelNode!
    private var accuracyLabel: SKLabelNode!
    private var levelLabel: SKLabelNode!
    private var progressBar: SKShapeNode!
    private var progressFill: SKShapeNode!
    private var bannerLabel: SKLabelNode!
    private var threatLabel: SKLabelNode!
    private var objectiveMarker: SKShapeNode!
    private var objectiveLabel: SKLabelNode!

    // Overlays
    private var damageVignette: SKSpriteNode!
    private var lowHealthPulse: SKSpriteNode!
    private var damageArrow: SKShapeNode!

    private var floaters: [SKLabelNode] = []
    private var style: CrosshairStyle = .classic
    private var crosshairScale: Float = 1
    private var showDamageNumbers = true

    // Animation state
    private var crosshairSpread: Float = 0
    private var hitMarkerLife: Float = 0
    private var hitMarkerIsKill = false
    private var bannerLife: Float = 0
    private var damageArrowLife: Float = 0
    private var damageArrowAngle: Float = 0
    private var lowHealthPhase: Float = 0

    private let mono = "Menlo-Bold"

    /// Set once `buildNodes()` has run. `SKScene.init(size:)` calls `setSize:`
    /// internally, which fires `didChangeSize` *before* the subclass initialiser
    /// body executes — so `layout()` runs against nil nodes and traps unless it
    /// is gated on this.
    private var nodesBuilt = false

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        buildNodes()
        nodesBuilt = true
        layout()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(gameplay: GameplaySettings) {
        guard nodesBuilt else { return }
        style = gameplay.crosshair
        crosshairScale = gameplay.crosshairScale
        showDamageNumbers = gameplay.showDamageNumbers
        rebuildCrosshair()
    }

    // MARK: Construction

    private func buildNodes() {
        // ---- Vignettes -------------------------------------------------------
        damageVignette = SKSpriteNode(texture: SKTexture(cgImage: HUD.vignetteImage(color: NSColor(rgb: 0.65, 0.02, 0.02))))
        damageVignette.alpha = 0
        damageVignette.zPosition = 50
        addChild(damageVignette)

        lowHealthPulse = SKSpriteNode(texture: SKTexture(cgImage: HUD.vignetteImage(color: NSColor(rgb: 0.45, 0.0, 0.0))))
        lowHealthPulse.alpha = 0
        lowHealthPulse.zPosition = 49
        addChild(lowHealthPulse)

        // ---- Crosshair -------------------------------------------------------
        crosshair.zPosition = 100
        addChild(crosshair)
        rebuildCrosshair()

        hitMarker.zPosition = 101
        hitMarker.alpha = 0
        addChild(hitMarker)
        for angle in [Float.pi / 4, 3 * .pi / 4, 5 * .pi / 4, 7 * .pi / 4] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: CGFloat(cos(angle)) * 7, y: CGFloat(sin(angle)) * 7))
            path.addLine(to: CGPoint(x: CGFloat(cos(angle)) * 15, y: CGFloat(sin(angle)) * 15))
            let arm = SKShapeNode(path: path)
            arm.strokeColor = .white
            arm.lineWidth = 2.4
            arm.lineCap = .round
            hitMarker.addChild(arm)
            hitMarkerArms.append(arm)
        }

        // ---- Health ----------------------------------------------------------
        healthBar = SKShapeNode(rectOf: CGSize(width: 260, height: 14), cornerRadius: 2)
        healthBar.strokeColor = NSColor(white: 1, alpha: 0.35)
        healthBar.fillColor = NSColor(white: 0, alpha: 0.45)
        healthBar.lineWidth = 1.5
        healthBar.zPosition = 60
        addChild(healthBar)

        healthFill = SKShapeNode(rectOf: CGSize(width: 256, height: 10), cornerRadius: 1)
        healthFill.strokeColor = .clear
        healthFill.fillColor = NSColor(rgb: 0.80, 0.13, 0.10)
        healthFill.zPosition = 61
        addChild(healthFill)

        healthText = label("100", size: 13, color: NSColor.Pal.ui)
        healthText.horizontalAlignmentMode = .left
        healthText.zPosition = 62
        addChild(healthText)

        // ---- Ammo ------------------------------------------------------------
        reloadArc = SKShapeNode()
        reloadArc.strokeColor = NSColor.Pal.hazard
        reloadArc.lineWidth = 3
        reloadArc.zPosition = 62
        addChild(reloadArc)

        reloadLabel = label("RELOADING", size: 12, color: NSColor.Pal.hazard)
        reloadLabel.alpha = 0
        reloadLabel.zPosition = 62
        addChild(reloadLabel)

        // ---- Score -----------------------------------------------------------
        scoreLabel = label("0", size: 26, color: NSColor.Pal.ui)
        scoreLabel.horizontalAlignmentMode = .left
        scoreLabel.zPosition = 60
        addChild(scoreLabel)

        comboLabel = label("", size: 17, color: NSColor.Pal.hazard)
        comboLabel.horizontalAlignmentMode = .left
        comboLabel.zPosition = 60
        addChild(comboLabel)

        accuracyLabel = label("ACC 100%", size: 12, color: NSColor.Pal.uiDim)
        accuracyLabel.horizontalAlignmentMode = .left
        accuracyLabel.zPosition = 60
        addChild(accuracyLabel)

        // ---- Level progress --------------------------------------------------
        levelLabel = label("", size: 12, color: NSColor.Pal.uiDim)
        levelLabel.zPosition = 60
        addChild(levelLabel)

        progressBar = SKShapeNode(rectOf: CGSize(width: 320, height: 3), cornerRadius: 1.5)
        progressBar.strokeColor = .clear
        progressBar.fillColor = NSColor(white: 1, alpha: 0.18)
        progressBar.zPosition = 60
        addChild(progressBar)

        progressFill = SKShapeNode(rectOf: CGSize(width: 320, height: 3), cornerRadius: 1.5)
        progressFill.strokeColor = .clear
        progressFill.fillColor = NSColor(rgb: 0.75, 0.70, 0.62)
        progressFill.zPosition = 61
        addChild(progressFill)

        threatLabel = label("", size: 13, color: NSColor.Pal.uiAccent)
        threatLabel.zPosition = 60
        addChild(threatLabel)

        // Objective marker: a chevron that slides along the top of the screen
        // pointing at the way on. Free movement makes "where do I go" a real
        // question that the rail version never had to answer.
        let chev = CGMutablePath()
        chev.move(to: CGPoint(x: -11, y: 7))
        chev.addLine(to: CGPoint(x: 0, y: -5))
        chev.addLine(to: CGPoint(x: 11, y: 7))
        objectiveMarker = SKShapeNode(path: chev)
        objectiveMarker.strokeColor = NSColor(rgb: 0.80, 0.76, 0.68, 0.9)
        objectiveMarker.lineWidth = 2.4
        objectiveMarker.lineCap = .round
        objectiveMarker.lineJoin = .round
        objectiveMarker.zPosition = 63
        objectiveMarker.alpha = 0
        addChild(objectiveMarker)

        objectiveLabel = label("THIS WAY", size: 9, color: NSColor(rgb: 0.70, 0.66, 0.60))
        objectiveLabel.zPosition = 63
        objectiveLabel.alpha = 0
        addChild(objectiveLabel)

        // ---- Banner ----------------------------------------------------------
        bannerLabel = label("", size: 30, color: NSColor.Pal.ui)
        bannerLabel.alpha = 0
        bannerLabel.zPosition = 70
        addChild(bannerLabel)

        // ---- Damage direction -------------------------------------------------
        let arrowPath = CGMutablePath()
        arrowPath.move(to: CGPoint(x: 0, y: 86))
        arrowPath.addLine(to: CGPoint(x: -20, y: 54))
        arrowPath.addLine(to: CGPoint(x: 0, y: 62))
        arrowPath.addLine(to: CGPoint(x: 20, y: 54))
        arrowPath.closeSubpath()
        damageArrow = SKShapeNode(path: arrowPath)
        damageArrow.fillColor = NSColor(rgb: 0.95, 0.15, 0.10, 0.85)
        damageArrow.strokeColor = .clear
        damageArrow.alpha = 0
        damageArrow.zPosition = 72
        addChild(damageArrow)
    }

    private func label(_ text: String, size: CGFloat, color: NSColor) -> SKLabelNode {
        let l = SKLabelNode(fontNamed: mono)
        l.text = text
        l.fontSize = size
        l.fontColor = color
        l.verticalAlignmentMode = .center
        return l
    }

    private func rebuildCrosshair() {
        crosshair.removeAllChildren()
        crosshairArms.removeAll()
        let s = CGFloat(crosshairScale)
        let colour = NSColor(rgb: 0.95, 0.93, 0.88, 0.9)

        switch style {
        case .classic:
            for angle in [Float(0), .pi / 2, .pi, 3 * .pi / 2] {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: CGFloat(cos(angle)) * 6 * s, y: CGFloat(sin(angle)) * 6 * s))
                path.addLine(to: CGPoint(x: CGFloat(cos(angle)) * 16 * s, y: CGFloat(sin(angle)) * 16 * s))
                let arm = SKShapeNode(path: path)
                arm.strokeColor = colour
                arm.lineWidth = 2 * s
                arm.lineCap = .round
                crosshair.addChild(arm)
                crosshairArms.append(arm)
            }
        case .dot:
            break
        case .circle:
            let ring = SKShapeNode(circleOfRadius: 13 * s)
            ring.strokeColor = colour
            ring.lineWidth = 1.8 * s
            ring.fillColor = .clear
            crosshair.addChild(ring)
            crosshairArms.append(ring)
        case .chevron:
            for (angle, len) in [(Float.pi * 0.75, CGFloat(14)), (Float.pi * 0.25, 14)] {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: CGFloat(cos(angle)) * 5 * s, y: CGFloat(sin(angle)) * 5 * s))
                path.addLine(to: CGPoint(x: CGFloat(cos(angle)) * len * s, y: CGFloat(sin(angle)) * len * s))
                let arm = SKShapeNode(path: path)
                arm.strokeColor = colour
                arm.lineWidth = 2.2 * s
                arm.lineCap = .round
                crosshair.addChild(arm)
                crosshairArms.append(arm)
            }
        }

        crosshairDot = SKShapeNode(circleOfRadius: 1.6 * s)
        crosshairDot.fillColor = colour
        crosshairDot.strokeColor = .clear
        crosshair.addChild(crosshairDot)
    }

    // MARK: Layout

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard nodesBuilt else { return }
        layout()
    }

    private func layout() {
        let w = size.width, h = size.height
        let margin: CGFloat = 34

        damageVignette.position = CGPoint(x: w / 2, y: h / 2)
        damageVignette.size = size
        lowHealthPulse.position = CGPoint(x: w / 2, y: h / 2)
        lowHealthPulse.size = size

        healthBar.position = CGPoint(x: margin + 130, y: margin + 24)
        healthText.position = CGPoint(x: margin, y: margin + 24)

        scoreLabel.position = CGPoint(x: margin, y: h - margin)
        comboLabel.position = CGPoint(x: margin, y: h - margin - 26)
        accuracyLabel.position = CGPoint(x: margin, y: h - margin - 48)

        levelLabel.position = CGPoint(x: w / 2, y: h - margin + 4)
        progressBar.position = CGPoint(x: w / 2, y: h - margin - 14)
        threatLabel.position = CGPoint(x: w / 2, y: h - margin - 34)

        bannerLabel.position = CGPoint(x: w / 2, y: h * 0.72)
        reloadLabel.position = CGPoint(x: w - margin - 90, y: margin + 60)
        layoutAmmo()
    }

    private func layoutAmmo() {
        for p in ammoPips { p.removeFromParent() }
        ammoPips.removeAll()
        let margin: CGFloat = 34
        let count = max(magazineSize, 1)
        let pipW: CGFloat = 9, gap: CGFloat = 5
        let total = CGFloat(count) * pipW + CGFloat(count - 1) * gap
        let startX = size.width - margin - total
        for i in 0..<count {
            let pip = SKShapeNode(rectOf: CGSize(width: pipW, height: 22), cornerRadius: 1.5)
            pip.position = CGPoint(x: startX + CGFloat(i) * (pipW + gap) + pipW / 2, y: margin + 24)
            pip.strokeColor = NSColor(white: 1, alpha: 0.30)
            pip.lineWidth = 1
            pip.fillColor = NSColor.Pal.hazard
            pip.zPosition = 60
            addChild(pip)
            ammoPips.append(pip)
        }
    }

    private var magazineSize = 8

    // MARK: Per-frame update

    struct Snapshot {
        var aim: CGPoint
        var health: Float
        var maxHealth: Float
        var ammo: Int
        var magazineSize: Int
        var reloading: Bool
        var reloadProgress: Float
        var score: Int
        var combo: Int
        var comboMultiplier: Float
        var accuracy: Float
        var levelName: String
        var progress: Float
        var threatsRemaining: Int
        var damageFlash: Float
        var isHolding: Bool
        /// -1..1 screen offset of the level-exit marker, or nil when ahead.
        var objectiveScreenX: Float?
    }

    func update(dt: Float, snapshot s: Snapshot) {
        guard nodesBuilt else { return }
        if s.magazineSize != magazineSize {
            magazineSize = s.magazineSize
            layoutAmmo()
        }

        // ---- Crosshair -------------------------------------------------------
        crosshair.position = s.aim
        crosshairSpread = damp(crosshairSpread, s.reloading ? 10 : 0, 9, dt)
        let base: CGFloat = 6 * CGFloat(crosshairScale)
        for (i, arm) in crosshairArms.enumerated() {
            // Fan the arms out while reloading, so the state is readable without
            // looking away from the target.
            let offset = CGFloat(crosshairSpread)
            arm.position = CGPoint(x: 0, y: 0)
            arm.setScale(1 + offset / 20)
            _ = i; _ = base
        }
        crosshairDot.alpha = s.reloading ? 0.35 : 1.0
        crosshair.alpha = s.isHolding ? 1.0 : 0.92

        hitMarker.position = s.aim
        if hitMarkerLife > 0 {
            hitMarkerLife = max(0, hitMarkerLife - dt)
            let t = hitMarkerLife / 0.22
            hitMarker.alpha = CGFloat(t)
            hitMarker.setScale(CGFloat(1.5 - t * 0.5))
            let c: NSColor = hitMarkerIsKill ? NSColor(rgb: 1.0, 0.25, 0.18) : .white
            for a in hitMarkerArms { a.strokeColor = c }
        } else {
            hitMarker.alpha = 0
        }

        // ---- Health ----------------------------------------------------------
        let frac = CGFloat(clamp01(s.health / max(s.maxHealth, 1)))
        healthFill.xScale = max(frac, 0.001)
        // The bar is centred, so shrinking it also has to shift it left.
        healthFill.position = CGPoint(x: healthBar.position.x - 128 + 128 * frac, y: healthBar.position.y)
        healthFill.fillColor = frac > 0.5 ? NSColor(rgb: 0.80, 0.13, 0.10)
                              : (frac > 0.25 ? NSColor(rgb: 0.90, 0.45, 0.08) : NSColor(rgb: 1.0, 0.20, 0.15))
        healthText.text = "\(Int(ceil(s.health)))"

        let healthFrac = Float(frac)
        lowHealthPhase += dt * (healthFrac < 0.25 ? Float(3.2) : Float(1.6))
        let lowT: Float = healthFrac < 0.35 ? (1 - healthFrac / 0.35) : 0
        let pulse: Float = 0.16 + 0.14 * (0.5 + 0.5 * sin(lowHealthPhase))
        lowHealthPulse.alpha = CGFloat(lowT * pulse)

        damageVignette.alpha = CGFloat(clamp01(s.damageFlash) * 0.55)

        // ---- Ammo ------------------------------------------------------------
        for (i, pip) in ammoPips.enumerated() {
            let loaded = i < s.ammo
            pip.fillColor = loaded ? NSColor.Pal.hazard : NSColor(white: 0.16, alpha: 0.55)
            pip.alpha = loaded ? 1 : 0.55
        }
        if s.reloading {
            reloadLabel.alpha = 1
            let r: CGFloat = 26
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: r, startAngle: .pi / 2,
                        endAngle: .pi / 2 - CGFloat(s.reloadProgress) * 2 * .pi,
                        clockwise: true)
            reloadArc.path = path
            reloadArc.position = s.aim
            reloadArc.alpha = 1
        } else {
            reloadLabel.alpha = 0
            reloadArc.alpha = 0
        }

        // ---- Score -----------------------------------------------------------
        scoreLabel.text = String(s.score)
        if s.combo >= 2 {
            comboLabel.text = String(format: "x%.1f  (%d)", s.comboMultiplier, s.combo)
            comboLabel.alpha = 1
        } else {
            comboLabel.alpha = 0
        }
        accuracyLabel.text = String(format: "ACC %d%%", Int(s.accuracy * 100))

        levelLabel.text = s.levelName
        progressFill.xScale = max(CGFloat(clamp01(s.progress)), 0.001)
        progressFill.position = CGPoint(x: progressBar.position.x - 160 + 160 * CGFloat(clamp01(s.progress)),
                                        y: progressBar.position.y)
        if s.isHolding && s.threatsRemaining > 0 {
            threatLabel.text = "AREA SEALED — \(s.threatsRemaining) REMAINING"
            threatLabel.alpha = 1
        } else {
            threatLabel.alpha = 0
        }

        // ---- Objective marker --------------------------------------------------
        if let ox = s.objectiveScreenX {
            let x = size.width / 2 + CGFloat(ox) * (size.width / 2 - 70)
            objectiveMarker.position = CGPoint(x: x, y: size.height - 96)
            objectiveMarker.zRotation = CGFloat(-ox) * 0.5
            objectiveLabel.position = CGPoint(x: x, y: size.height - 114)
            let a = CGFloat(0.35 + 0.45 * abs(ox))
            objectiveMarker.alpha = a
            objectiveLabel.alpha = a * 0.8
        } else {
            objectiveMarker.alpha = 0
            objectiveLabel.alpha = 0
        }

        // ---- Banner ----------------------------------------------------------
        if bannerLife > 0 {
            bannerLife = max(0, bannerLife - dt)
            let t = bannerLife / 2.4
            bannerLabel.alpha = CGFloat(smoothstep(0, 0.25, t) * smoothstep(1.0, 0.75, t) + (t > 0.75 ? 1 : 0))
            bannerLabel.alpha = CGFloat(min(1, smoothstep(0, 0.2, t) * 1.4))
        } else {
            bannerLabel.alpha = 0
        }

        // ---- Damage arrow -----------------------------------------------------
        if damageArrowLife > 0 {
            damageArrowLife = max(0, damageArrowLife - dt)
            damageArrow.alpha = CGFloat(clamp01(damageArrowLife / 1.1))
            damageArrow.position = CGPoint(x: size.width / 2, y: size.height / 2)
            damageArrow.zRotation = CGFloat(-damageArrowAngle)
        } else {
            damageArrow.alpha = 0
        }

        // ---- Floating numbers -------------------------------------------------
        floaters.removeAll { $0.parent == nil }
    }

    // MARK: Events

    func showHitMarker(kill: Bool) {
        hitMarkerLife = 0.22
        hitMarkerIsKill = kill
    }

    func showBanner(_ text: String) {
        bannerLabel.text = text
        bannerLife = 2.4
    }

    /// `angle` is the bearing of the attacker relative to where the player faces,
    /// in radians (0 = straight ahead).
    func showDamageDirection(_ angle: Float) {
        damageArrowAngle = angle
        damageArrowLife = 1.1
    }

    /// Floating score/label text at a screen position.
    func floatText(_ text: String, at point: CGPoint, color: NSColor, size fontSize: CGFloat = 15) {
        guard showDamageNumbers else { return }
        // Cap the number of live floaters; a big wave can produce dozens at once.
        if floaters.count > 14 {
            floaters.removeFirst().removeFromParent()
        }
        let l = label(text, size: fontSize, color: color)
        l.position = point
        l.zPosition = 80
        l.alpha = 0.95
        addChild(l)
        floaters.append(l)
        l.run(.sequence([
            .group([.moveBy(x: 0, y: 46, duration: 0.85), .fadeOut(withDuration: 0.85)]),
            .removeFromParentNode()
        ]))
    }

    // MARK: Assets

    /// Radial vignette used for damage and low-health overlays.
    private static func vignetteImage(color: NSColor) -> CGImage {
        let n = 256
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        let r = CGFloat(color.redComponent), g = CGFloat(color.greenComponent), b = CGFloat(color.blueComponent)
        let rB = UInt8(clamp01(Float(r)) * 255)
        let gB = UInt8(clamp01(Float(g)) * 255)
        let bB = UInt8(clamp01(Float(b)) * 255)
        let inv = 1 / Float(n - 1)
        for y in 0..<n {
            for x in 0..<n {
                let dx: Float = Float(x) * inv * 2 - 1
                let dy: Float = Float(y) * inv * 2 - 1
                let d: Float = sqrt(dx * dx + dy * dy) / 1.414
                let a: Float = smoothstep(0.35, 1.0, d)
                let i = (y * n + x) * 4
                bytes[i + 0] = rB
                bytes[i + 1] = gB
                bytes[i + 2] = bB
                bytes[i + 3] = UInt8(clamp01(a) * 255)
            }
        }
        var data = bytes
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

private extension SKAction {
    static func removeFromParentNode() -> SKAction { .removeFromParent() }
}
