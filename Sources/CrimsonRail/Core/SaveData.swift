import Foundation

/// Letter grade shown on the results screen and level select.
enum Rank: String, Codable, CaseIterable {
    case s = "S", a = "A", b = "B", c = "C", d = "D"

    var order: Int {
        switch self {
        case .s: return 5; case .a: return 4; case .b: return 3; case .c: return 2; case .d: return 1
        }
    }

    /// Weighted so that a clean run matters more than a slow grind: accuracy and
    /// survival dominate, raw score only breaks ties.
    static func evaluate(accuracy: Float, healthFraction: Float, killFraction: Float, comboBest: Int) -> Rank {
        var pts: Float = 0
        pts += accuracy * 45                        // 0..45
        pts += healthFraction * 30                  // 0..30
        pts += killFraction * 15                    // 0..15
        pts += min(Float(comboBest) / 25, 1) * 10   // 0..10
        switch pts {
        case 88...: return .s
        case 74..<88: return .a
        case 58..<74: return .b
        case 40..<58: return .c
        default: return .d
        }
    }
}

struct LevelRecord: Codable, Equatable {
    var completed = false
    var bestScore = 0
    var bestAccuracy: Float = 0
    var bestRank: Rank? = nil
    var bestTime: Float = 0
    var attempts = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LevelRecord()
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? d.completed
        bestScore = try c.decodeIfPresent(Int.self, forKey: .bestScore) ?? d.bestScore
        bestAccuracy = try c.decodeIfPresent(Float.self, forKey: .bestAccuracy) ?? d.bestAccuracy
        bestRank = try c.decodeIfPresent(Rank.self, forKey: .bestRank) ?? d.bestRank
        bestTime = try c.decodeIfPresent(Float.self, forKey: .bestTime) ?? d.bestTime
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? d.attempts
    }
}

struct SaveData: Codable {
    /// Index of the highest level the player may enter (0-based).
    var highestUnlocked = 0
    var levels: [LevelRecord] = Array(repeating: LevelRecord(), count: LevelCatalog.count)
    var totalKills = 0
    var totalShots = 0
    var totalHits = 0
    var totalPlayTime: Float = 0
    var headshots = 0
    var survivorsSaved = 0
    var campaignCleared = false

    init() {}

    /// Same defensive shape as Settings: every key optional with a default, so a
    /// new field in a future build cannot wipe a player's progress.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SaveData()
        highestUnlocked = try c.decodeIfPresent(Int.self, forKey: .highestUnlocked) ?? d.highestUnlocked
        levels = try c.decodeIfPresent([LevelRecord].self, forKey: .levels) ?? d.levels
        totalKills = try c.decodeIfPresent(Int.self, forKey: .totalKills) ?? d.totalKills
        totalShots = try c.decodeIfPresent(Int.self, forKey: .totalShots) ?? d.totalShots
        totalHits = try c.decodeIfPresent(Int.self, forKey: .totalHits) ?? d.totalHits
        totalPlayTime = try c.decodeIfPresent(Float.self, forKey: .totalPlayTime) ?? d.totalPlayTime
        headshots = try c.decodeIfPresent(Int.self, forKey: .headshots) ?? d.headshots
        survivorsSaved = try c.decodeIfPresent(Int.self, forKey: .survivorsSaved) ?? d.survivorsSaved
        campaignCleared = try c.decodeIfPresent(Bool.self, forKey: .campaignCleared) ?? d.campaignCleared

        // A shorter array than the current catalog is normal after adding levels.
        if levels.count < LevelCatalog.count {
            levels.append(contentsOf: Array(repeating: LevelRecord(), count: LevelCatalog.count - levels.count))
        }
        highestUnlocked = min(max(highestUnlocked, 0), LevelCatalog.count - 1)
    }

    var lifetimeAccuracy: Float {
        totalShots > 0 ? Float(totalHits) / Float(totalShots) : 0
    }

    func isUnlocked(_ index: Int) -> Bool { index <= highestUnlocked }

    /// Folds a finished run into the save. Returns true if anything improved.
    @discardableResult
    mutating func record(levelIndex: Int, result: RunResult) -> Bool {
        guard levels.indices.contains(levelIndex) else { return false }
        var improved = false
        levels[levelIndex].attempts += 1
        totalKills += result.kills
        totalShots += result.shots
        totalHits += result.hits
        headshots += result.headshots
        survivorsSaved += result.survivorsSaved
        totalPlayTime += result.duration

        if result.won {
            if !levels[levelIndex].completed { improved = true }
            levels[levelIndex].completed = true
            if levelIndex + 1 > highestUnlocked && levelIndex + 1 < LevelCatalog.count {
                highestUnlocked = levelIndex + 1
                improved = true
            }
            if levelIndex == LevelCatalog.count - 1 { campaignCleared = true }
            if levels[levelIndex].bestTime == 0 || result.duration < levels[levelIndex].bestTime {
                levels[levelIndex].bestTime = result.duration
            }
        }
        if result.score > levels[levelIndex].bestScore {
            levels[levelIndex].bestScore = result.score
            improved = true
        }
        if result.accuracy > levels[levelIndex].bestAccuracy {
            levels[levelIndex].bestAccuracy = result.accuracy
        }
        if result.won {
            let r = result.rank
            if (levels[levelIndex].bestRank?.order ?? 0) < r.order {
                levels[levelIndex].bestRank = r
                improved = true
            }
        }
        return improved
    }

    static func load() -> SaveData {
        guard !Store.isolated,
              let data = try? Data(contentsOf: Store.saveURL),
              let s = try? JSONDecoder().decode(SaveData.self, from: data)
        else { return SaveData() }
        return s
    }

    func persist() {
        guard !Store.isolated else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Store.saveURL, options: .atomic)
    }
}

/// Everything a finished run reports back.
struct RunResult {
    var won = false
    var score = 0
    var kills = 0
    var totalThreats = 0
    var shots = 0
    var hits = 0
    var headshots = 0
    var survivorsSaved = 0
    var survivorsLost = 0
    var bestCombo = 0
    var duration: Float = 0
    var healthRemaining: Float = 0
    var healthMax: Float = 100

    var accuracy: Float { shots > 0 ? Float(hits) / Float(shots) : 0 }
    var killFraction: Float { totalThreats > 0 ? Float(kills) / Float(totalThreats) : 0 }
    var healthFraction: Float { healthMax > 0 ? clamp01(healthRemaining / healthMax) : 0 }

    var rank: Rank {
        Rank.evaluate(accuracy: accuracy,
                      healthFraction: healthFraction,
                      killFraction: killFraction,
                      comboBest: bestCombo)
    }
}
