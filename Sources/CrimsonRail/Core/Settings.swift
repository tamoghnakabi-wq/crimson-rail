import Foundation
import Metal
import SceneKit

// MARK: - Quality

enum QualityPreset: String, CaseIterable, Codable {
    case low, medium, high, ultra

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }

    var blurb: String {
        switch self {
        case .low: return "Older Intel Macs and integrated graphics."
        case .medium: return "M1 / M2 Air, or any Mac needing headroom."
        case .high: return "M-series Pro and above. Recommended."
        case .ultra: return "Max / Ultra chips and discrete GPUs."
        }
    }
}

/// Everything the renderer reads. Presets write these; the settings screen can
/// then override any single field (which flips `preset` to a custom-ish state
/// only in the UI — the stored values are what matter).
struct GraphicsSettings: Codable, Equatable {
    var preset: QualityPreset = .high

    var shadowsEnabled: Bool = true
    var shadowMapSize: Int = 2048
    var shadowCascades: Int = 2
    /// Extra shadow-casting lights beyond the level's key light.
    var maxShadowCastingLights: Int = 3

    var ambientOcclusion: Bool = true
    var bloom: Bool = true
    var hdr: Bool = true
    var motionBlur: Bool = false
    var filmGrain: Bool = true
    var vignette: Bool = true
    var colorFringe: Bool = true

    var antialiasing: Int = 2          // 0 = off, 2 = 2x, 4 = 4x MSAA
    var renderScale: Float = 1.0       // relative to backing store
    var particleBudget: Float = 1.0    // multiplier on birth rates and counts
    var decalBudget: Int = 96
    var maxCorpses: Int = 10
    var drawDistance: Float = 130
    var propDensity: Float = 1.0
    var frameRateCap: Int = 0          // 0 = display refresh

    static func forPreset(_ p: QualityPreset) -> GraphicsSettings {
        var g = GraphicsSettings()
        g.preset = p
        switch p {
        case .low:
            g.shadowsEnabled = false
            g.shadowMapSize = 512; g.shadowCascades = 1; g.maxShadowCastingLights = 0
            g.ambientOcclusion = false; g.bloom = false; g.hdr = false
            g.motionBlur = false; g.filmGrain = false; g.colorFringe = false
            g.antialiasing = 0; g.renderScale = 0.75
            g.particleBudget = 0.35; g.decalBudget = 16; g.maxCorpses = 3
            g.drawDistance = 70; g.propDensity = 0.5
        case .medium:
            g.shadowsEnabled = true
            g.shadowMapSize = 1024; g.shadowCascades = 1; g.maxShadowCastingLights = 1
            g.ambientOcclusion = false; g.bloom = true; g.hdr = true
            g.motionBlur = false; g.filmGrain = true; g.colorFringe = false
            g.antialiasing = 0; g.renderScale = 0.9
            g.particleBudget = 0.65; g.decalBudget = 40; g.maxCorpses = 6
            g.drawDistance = 100; g.propDensity = 0.75
        case .high:
            g.shadowsEnabled = true
            // Only the key light casts. Every shadow-casting *omni* light renders
            // a six-face cube map, and a street with a dozen lamps in range spent
            // 6 ms/frame on them — over a third of the 60 Hz budget — for shadows
            // the player never looks at. Ultra can afford them; High cannot.
            g.shadowMapSize = 2048; g.shadowCascades = 2; g.maxShadowCastingLights = 1
            g.ambientOcclusion = true; g.bloom = true; g.hdr = true
            g.motionBlur = false; g.filmGrain = true; g.colorFringe = true
            // No MSAA on High. On a Retina display the backing store is already
            // 2x, which anti-aliases better than 2x MSAA does at a fraction of
            // the cost — measured at roughly a third of the frame budget on the
            // heavier levels. Ultra keeps it for non-Retina and large displays.
            g.antialiasing = 0; g.renderScale = 1.0
            g.particleBudget = 1.0; g.decalBudget = 96; g.maxCorpses = 10
            g.drawDistance = 130; g.propDensity = 1.0
        case .ultra:
            g.shadowsEnabled = true
            g.shadowMapSize = 4096; g.shadowCascades = 3; g.maxShadowCastingLights = 5
            g.ambientOcclusion = true; g.bloom = true; g.hdr = true
            g.motionBlur = true; g.filmGrain = true; g.colorFringe = true
            g.antialiasing = 4; g.renderScale = 1.0
            g.particleBudget = 1.5; g.decalBudget = 160; g.maxCorpses = 16
            g.drawDistance = 180; g.propDensity = 1.3
        }
        return g
    }

    /// Hand-written so adding a field never invalidates an existing settings file.
    /// (A synthesised `init(from:)` throws on any missing key, and a `try?`
    /// decode answers that by silently resetting everything.)
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphicsSettings()
        preset = try c.decodeIfPresent(QualityPreset.self, forKey: .preset) ?? d.preset
        shadowsEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowsEnabled) ?? d.shadowsEnabled
        shadowMapSize = try c.decodeIfPresent(Int.self, forKey: .shadowMapSize) ?? d.shadowMapSize
        shadowCascades = try c.decodeIfPresent(Int.self, forKey: .shadowCascades) ?? d.shadowCascades
        maxShadowCastingLights = try c.decodeIfPresent(Int.self, forKey: .maxShadowCastingLights) ?? d.maxShadowCastingLights
        ambientOcclusion = try c.decodeIfPresent(Bool.self, forKey: .ambientOcclusion) ?? d.ambientOcclusion
        bloom = try c.decodeIfPresent(Bool.self, forKey: .bloom) ?? d.bloom
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
        motionBlur = try c.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? d.motionBlur
        filmGrain = try c.decodeIfPresent(Bool.self, forKey: .filmGrain) ?? d.filmGrain
        vignette = try c.decodeIfPresent(Bool.self, forKey: .vignette) ?? d.vignette
        colorFringe = try c.decodeIfPresent(Bool.self, forKey: .colorFringe) ?? d.colorFringe
        antialiasing = try c.decodeIfPresent(Int.self, forKey: .antialiasing) ?? d.antialiasing
        renderScale = try c.decodeIfPresent(Float.self, forKey: .renderScale) ?? d.renderScale
        particleBudget = try c.decodeIfPresent(Float.self, forKey: .particleBudget) ?? d.particleBudget
        decalBudget = try c.decodeIfPresent(Int.self, forKey: .decalBudget) ?? d.decalBudget
        maxCorpses = try c.decodeIfPresent(Int.self, forKey: .maxCorpses) ?? d.maxCorpses
        drawDistance = try c.decodeIfPresent(Float.self, forKey: .drawDistance) ?? d.drawDistance
        propDensity = try c.decodeIfPresent(Float.self, forKey: .propDensity) ?? d.propDensity
        frameRateCap = try c.decodeIfPresent(Int.self, forKey: .frameRateCap) ?? d.frameRateCap
    }
}

// MARK: - Audio / gameplay

struct AudioSettings: Codable, Equatable {
    var master: Float = 0.85
    var sfx: Float = 1.0
    var music: Float = 0.6
    var ambience: Float = 0.75

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioSettings()
        master = try c.decodeIfPresent(Float.self, forKey: .master) ?? d.master
        sfx = try c.decodeIfPresent(Float.self, forKey: .sfx) ?? d.sfx
        music = try c.decodeIfPresent(Float.self, forKey: .music) ?? d.music
        ambience = try c.decodeIfPresent(Float.self, forKey: .ambience) ?? d.ambience
    }
}

enum Difficulty: String, CaseIterable, Codable {
    case rookie, agent, nightmare

    var displayName: String {
        switch self {
        case .rookie: return "Rookie"
        case .agent: return "Agent"
        case .nightmare: return "Nightmare"
        }
    }
    var blurb: String {
        switch self {
        case .rookie: return "More health, slower attackers. Learn the routes."
        case .agent: return "The intended experience."
        case .nightmare: return "They are faster, they hit harder, and there are more of them."
        }
    }
    /// Multiplies incoming damage.
    var damageTaken: Float {
        switch self {
        case .rookie: return 0.6
        case .agent: return 1.0
        case .nightmare: return 1.6
        }
    }
    /// Multiplies zombie move speed and shortens attack wind-up.
    var enemyAggression: Float {
        switch self {
        case .rookie: return 0.82
        case .agent: return 1.0
        case .nightmare: return 1.22
        }
    }
    var startingHealth: Float {
        switch self {
        case .rookie: return 160
        case .agent: return 115
        case .nightmare: return 80
        }
    }
    var scoreMultiplier: Float {
        switch self {
        case .rookie: return 0.75
        case .agent: return 1.0
        case .nightmare: return 1.4
        }
    }
}

enum CrosshairStyle: String, CaseIterable, Codable {
    case classic, dot, circle, chevron
    var displayName: String { rawValue.capitalized }
}

struct GameplaySettings: Codable, Equatable {
    var difficulty: Difficulty = .agent
    var crosshair: CrosshairStyle = .classic
    var crosshairScale: Float = 1.0
    var screenShake: Float = 1.0
    var goreLevel: Float = 1.0          // 0 disables blood entirely
    var cameraSway: Float = 1.0         // cinematic handheld motion
    var showDamageNumbers: Bool = true
    var invertReloadButton: Bool = false // right-click fires, left reloads
    /// Mouse-look sensitivity multiplier.
    var lookSensitivity: Float = 1.0
    var invertLookY: Bool = false
    var fullscreenOnLaunch: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameplaySettings()
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty) ?? d.difficulty
        crosshair = try c.decodeIfPresent(CrosshairStyle.self, forKey: .crosshair) ?? d.crosshair
        crosshairScale = try c.decodeIfPresent(Float.self, forKey: .crosshairScale) ?? d.crosshairScale
        screenShake = try c.decodeIfPresent(Float.self, forKey: .screenShake) ?? d.screenShake
        goreLevel = try c.decodeIfPresent(Float.self, forKey: .goreLevel) ?? d.goreLevel
        cameraSway = try c.decodeIfPresent(Float.self, forKey: .cameraSway) ?? d.cameraSway
        showDamageNumbers = try c.decodeIfPresent(Bool.self, forKey: .showDamageNumbers) ?? d.showDamageNumbers
        invertReloadButton = try c.decodeIfPresent(Bool.self, forKey: .invertReloadButton) ?? d.invertReloadButton
        lookSensitivity = try c.decodeIfPresent(Float.self, forKey: .lookSensitivity) ?? d.lookSensitivity
        invertLookY = try c.decodeIfPresent(Bool.self, forKey: .invertLookY) ?? d.invertLookY
        fullscreenOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .fullscreenOnLaunch) ?? d.fullscreenOnLaunch
    }
}

// MARK: - Root settings document

struct Settings: Codable, Equatable {
    var graphics: GraphicsSettings = .forPreset(.high)
    var audio = AudioSettings()
    var gameplay = GameplaySettings()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graphics = try c.decodeIfPresent(GraphicsSettings.self, forKey: .graphics) ?? .forPreset(.high)
        audio = try c.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? AudioSettings()
        gameplay = try c.decodeIfPresent(GameplaySettings.self, forKey: .gameplay) ?? GameplaySettings()
    }

    /// Chooses a starting preset from the actual GPU rather than shipping every
    /// Mac the same defaults. Refined at runtime only if the user never touches it.
    static func autoDetectPreset() -> QualityPreset {
        guard let device = MTLCreateSystemDefaultDevice() else { return .medium }
        let name = device.name.lowercased()
        if name.contains("ultra") || name.contains("max") { return .ultra }
        if name.contains("pro") { return .high }
        if name.contains("apple m") {
            // Base M-series: plenty for High at this scene complexity.
            return .high
        }
        if device.supportsFamily(.apple7) { return .medium }
        return .low
    }
}

// MARK: - Persistence

enum Store {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("CrimsonRail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    static var saveURL: URL { directory.appendingPathComponent("progress.json") }

    /// Set by `--isolated` so harness runs never read or clobber a real player's files.
    static var isolated = false

    static func loadSettings() -> Settings {
        guard !isolated,
              let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            var s = Settings()
            s.graphics = .forPreset(Settings.autoDetectPreset())
            return s
        }
        return s
    }

    /// Number of times settings have actually been written. Used by the tests to
    /// prove the settings screen is not writing on every slider tick.
    private(set) static var writeCount = 0

    static func save(_ settings: Settings) {
        writeCount += 1
        guard !isolated else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(settings).write(to: settingsURL, options: .atomic)
    }
}
