import Foundation
import simd

// MARK: - Authoring types
//
// Spawns are anchored to the *rail*, not to world space: a spawn says "12 metres
// further along, 4 metres to the left". Re-shaping a path then moves its
// encounters with it instead of stranding them in a wall.

struct SpawnDef {
    var kind: ZombieKind
    /// Rail distance the spawn is anchored to.
    var railDistance: Float
    /// Metres to the right of the direction of travel; negative is left.
    var lateral: Float
    /// Height above the rail's ground plane — windows, balconies, stairs.
    var height: Float = 0
    /// Seconds after its wave begins.
    var delay: Float = 0
    /// Emerges from cover rather than simply being there (plays a rise/stagger-in).
    var entrance: Entrance = .lurch

    enum Entrance {
        case lurch          // steps out of the dark
        case riseFromGround // claws up out of soil/rubble
        case burstThrough   // smashes a window/door
        case dropFromAbove  // falls in from a ledge
    }
}

struct WaveDef {
    /// Seconds after the encounter starts, or after the previous wave clears.
    var startDelay: Float = 0
    /// When true this wave waits for the previous one to be wiped out.
    var afterPreviousCleared: Bool = true
    var spawns: [SpawnDef]
}

enum GazeTarget {
    /// Look along the rail.
    case forward
    /// Turn relative to the rail tangent, in degrees.
    case offset(yaw: Float, pitch: Float)
    /// Look at a fixed world point.
    case point(SIMD3<Float>)
}

/// A civilian in danger. Shooting one is heavily penalised; getting them out
/// alive is worth a large bonus and a health pickup.
struct SurvivorDef {
    var railDistance: Float
    var lateral: Float
    /// Cleared when every zombie in the encounter is dead.
    var rescueBonus: Int = 2500
    var healthReward: Float = 20
}

struct EncounterDef {
    var id: String
    /// Rail distance at which the encounter fires.
    var triggerDistance: Float
    /// Whether the camera holds here until the encounter is cleared.
    var holdPosition: Bool = true
    var gaze: GazeTarget = .forward
    var waves: [WaveDef]
    var banner: String? = nil
    var survivor: SurvivorDef? = nil
    /// Encounter fails over to "proceed anyway" after this long, so a lost
    /// enemy stuck on geometry can never soft-lock a run.
    var failsafeTimeout: Float = 75

    var threatCount: Int { waves.reduce(0) { $0 + $1.spawns.count } }
}

enum EnvironmentKind: String {
    case cemetery, manor, street, lab, spire
}

struct LevelDef {
    var index: Int
    var name: String
    var subtitle: String
    var environment: EnvironmentKind
    /// Rail control points, in metres.
    var railPoints: [SIMD3<Float>]
    /// Base travel speed in m/s between encounters.
    var travelSpeed: Float
    var encounters: [EncounterDef]
    /// Spawns that fire while the camera keeps moving — keeps travel alive.
    var ambushes: [SpawnDef] = []
    /// Flavour text on the briefing card.
    var briefing: String
    var seed: UInt64

    var totalThreats: Int {
        encounters.reduce(0) { $0 + $1.threatCount } + ambushes.count
    }
}

// MARK: - Catalog

enum LevelCatalog {
    static var count: Int { all.count }

    static func level(_ index: Int) -> LevelDef {
        all[min(max(index, 0), all.count - 1)]
    }

    static let all: [LevelDef] = [cemetery, manor, street, lab, spire]

    // MARK: 1 — Ashwood Cemetery

    static let cemetery = LevelDef(
        index: 0,
        name: "THE GATE",
        subtitle: "Ashwood Cemetery — 02:14",
        environment: .cemetery,
        railPoints: [
            SIMD3(0, 0, -6), SIMD3(0, 0, 8), SIMD3(2.5, 0, 22), SIMD3(3.0, 0, 36),
            SIMD3(-2.5, 0, 50), SIMD3(-3.5, 0, 64), SIMD3(0, 0, 78), SIMD3(1.5, 0, 92),
            SIMD3(0.5, 1.4, 106), SIMD3(0, 2.2, 116)
        ],
        travelSpeed: 2.7,
        encounters: [
            EncounterDef(
                id: "c1", triggerDistance: 16, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.5, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 27, lateral: -2.5, entrance: .riseFromGround),
                        SpawnDef(kind: .shambler, railDistance: 29, lateral: 3.0, delay: 1.1, entrance: .riseFromGround)
                    ]),
                    WaveDef(startDelay: 0.6, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 26, lateral: 5.5),
                        SpawnDef(kind: .shambler, railDistance: 31, lateral: -5.0, delay: 0.8)
                    ])
                ],
                banner: "THEY ARE ALREADY AWAKE"),
            EncounterDef(
                id: "c2", triggerDistance: 34, gaze: .offset(yaw: -22, pitch: 0),
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 40, lateral: -7.0, entrance: .riseFromGround),
                        SpawnDef(kind: .shambler, railDistance: 44, lateral: -4.0, delay: 0.9),
                        SpawnDef(kind: .runner, railDistance: 47, lateral: -1.0, delay: 2.2)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 42, lateral: 6.0),
                        SpawnDef(kind: .runner, railDistance: 45, lateral: 2.5, delay: 1.4)
                    ])
                ]),
            EncounterDef(
                id: "c3", triggerDistance: 54, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.4, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 62, lateral: 0.5),
                        SpawnDef(kind: .shambler, railDistance: 64, lateral: -3.5, delay: 0.6),
                        SpawnDef(kind: .shambler, railDistance: 63, lateral: 4.0, delay: 1.2),
                        SpawnDef(kind: .runner, railDistance: 68, lateral: -1.5, delay: 2.6)
                    ])
                ],
                banner: "CIVILIAN — HOLD YOUR FIRE",
                survivor: SurvivorDef(railDistance: 66, lateral: 2.0)),
            EncounterDef(
                id: "c4", triggerDistance: 74, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 82, lateral: -2.0),
                        SpawnDef(kind: .runner, railDistance: 84, lateral: 2.5, delay: 0.7),
                        SpawnDef(kind: .shambler, railDistance: 86, lateral: -5.5, delay: 1.0),
                        SpawnDef(kind: .shambler, railDistance: 87, lateral: 5.0, delay: 1.5)
                    ]),
                    WaveDef(startDelay: 0.8, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 88, lateral: 0, entrance: .riseFromGround),
                        SpawnDef(kind: .shambler, railDistance: 90, lateral: -3.0, delay: 0.7, entrance: .riseFromGround),
                        SpawnDef(kind: .runner, railDistance: 92, lateral: 3.0, delay: 1.6)
                    ])
                ]),
            EncounterDef(
                id: "c5", triggerDistance: 100, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.4, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 110, lateral: -3.0),
                        SpawnDef(kind: .shambler, railDistance: 111, lateral: 3.0, delay: 0.4),
                        SpawnDef(kind: .runner, railDistance: 113, lateral: 0, delay: 1.3),
                        SpawnDef(kind: .runner, railDistance: 112, lateral: -5.0, delay: 2.0),
                        SpawnDef(kind: .runner, railDistance: 112, lateral: 5.0, delay: 2.4)
                    ])
                ],
                banner: "REACH THE CHAPEL"),
        ],
        ambushes: [
            SpawnDef(kind: .shambler, railDistance: 22, lateral: -8.0, delay: 0),
            SpawnDef(kind: .shambler, railDistance: 48, lateral: 8.5, delay: 0),
            SpawnDef(kind: .shambler, railDistance: 96, lateral: -7.0, delay: 0)
        ],
        briefing: "The cemetery gate was open when the first call came in. Nothing that went in has come back out. Move to the chapel and find out why.",
        seed: 1001)

    // MARK: 2 — Ashwood Manor

    static let manor = LevelDef(
        index: 1,
        name: "GUEST OF THE HOUSE",
        subtitle: "Ashwood Manor — 02:51",
        environment: .manor,
        railPoints: [
            SIMD3(0, 0, -4), SIMD3(0, 0, 10), SIMD3(0, 0, 24),
            SIMD3(6, 0, 34), SIMD3(14, 0, 38), SIMD3(24, 0, 38),
            SIMD3(32, 0, 32), SIMD3(36, 0, 20), SIMD3(36, 0, 6),
            SIMD3(30, 0, -4), SIMD3(20, 0, -8), SIMD3(10, 0, -8)
        ],
        travelSpeed: 2.8,
        encounters: [
            EncounterDef(
                id: "m1", triggerDistance: 14, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.4, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 22, lateral: -2.0),
                        SpawnDef(kind: .shambler, railDistance: 23, lateral: 2.0, delay: 0.5),
                        SpawnDef(kind: .crawler, railDistance: 25, lateral: 0, delay: 1.6, entrance: .riseFromGround)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .runner, railDistance: 26, lateral: -3.0, entrance: .burstThrough),
                        SpawnDef(kind: .crawler, railDistance: 27, lateral: 3.0, delay: 0.9),
                        SpawnDef(kind: .shambler, railDistance: 28, lateral: 0, delay: 1.8)
                    ])
                ],
                banner: "THE HOUSE IS NOT EMPTY"),
            EncounterDef(
                id: "m2", triggerDistance: 34, gaze: .offset(yaw: 30, pitch: 6),
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .crawler, railDistance: 42, lateral: -2.0),
                        SpawnDef(kind: .crawler, railDistance: 43, lateral: 2.5, delay: 0.6),
                        SpawnDef(kind: .runner, railDistance: 45, lateral: 0, delay: 1.4),
                        SpawnDef(kind: .shambler, railDistance: 44, lateral: 4.5, height: 3.2, delay: 2.0, entrance: .dropFromAbove)
                    ]),
                    WaveDef(startDelay: 0.6, spawns: [
                        SpawnDef(kind: .runner, railDistance: 46, lateral: -4.0),
                        SpawnDef(kind: .runner, railDistance: 47, lateral: 4.0, delay: 0.5),
                        SpawnDef(kind: .crawler, railDistance: 48, lateral: 0, delay: 1.2),
                        SpawnDef(kind: .shambler, railDistance: 49, lateral: -2.0, delay: 1.9)
                    ])
                ]),
            EncounterDef(
                id: "m3", triggerDistance: 56, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.4, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 64, lateral: -3.0),
                        SpawnDef(kind: .shambler, railDistance: 65, lateral: 3.0, delay: 0.5),
                        SpawnDef(kind: .runner, railDistance: 67, lateral: -1.0, delay: 1.5),
                        SpawnDef(kind: .runner, railDistance: 67, lateral: 1.0, delay: 1.9)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .brute, railDistance: 70, lateral: 0, delay: 0.2, entrance: .burstThrough),
                        SpawnDef(kind: .crawler, railDistance: 68, lateral: -4.0, delay: 1.4),
                        SpawnDef(kind: .crawler, railDistance: 68, lateral: 4.0, delay: 1.8)
                    ])
                ],
                banner: "ARMOURED — AIM FOR THE HEAD"),
            EncounterDef(
                id: "m4", triggerDistance: 78, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.4, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 86, lateral: -2.5),
                        SpawnDef(kind: .crawler, railDistance: 87, lateral: 2.5, delay: 0.6),
                        SpawnDef(kind: .shambler, railDistance: 88, lateral: -5.0, delay: 1.2),
                        SpawnDef(kind: .shambler, railDistance: 88, lateral: 5.0, delay: 1.6)
                    ])
                ],
                banner: "CIVILIAN — HOLD YOUR FIRE",
                survivor: SurvivorDef(railDistance: 90, lateral: -1.5)),
            EncounterDef(
                id: "m5", triggerDistance: 100, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .crawler, railDistance: 108, lateral: -3.0),
                        SpawnDef(kind: .crawler, railDistance: 108, lateral: 3.0, delay: 0.4),
                        SpawnDef(kind: .runner, railDistance: 110, lateral: 0, delay: 1.0),
                        SpawnDef(kind: .runner, railDistance: 111, lateral: -4.5, delay: 1.5),
                        SpawnDef(kind: .runner, railDistance: 111, lateral: 4.5, delay: 1.9)
                    ]),
                    WaveDef(startDelay: 0.7, spawns: [
                        SpawnDef(kind: .brute, railDistance: 113, lateral: -2.0),
                        SpawnDef(kind: .brute, railDistance: 113, lateral: 2.0, delay: 1.2),
                        SpawnDef(kind: .shambler, railDistance: 112, lateral: 0, delay: 2.4, entrance: .riseFromGround)
                    ])
                ],
                banner: "GET OUT OF THE HOUSE"),
        ],
        ambushes: [
            SpawnDef(kind: .crawler, railDistance: 30, lateral: -5.0),
            SpawnDef(kind: .shambler, railDistance: 50, lateral: 5.5),
            SpawnDef(kind: .crawler, railDistance: 72, lateral: -5.0),
            SpawnDef(kind: .runner, railDistance: 94, lateral: 5.0)
        ],
        briefing: "The Ashwood family stopped answering three days ago. The chapel tunnel comes up in their cellar. Whatever started here, it started inside this house.",
        seed: 2002)

    // MARK: 3 — Ruined Quarter

    static let street = LevelDef(
        index: 2,
        name: "FIRE IN THE STREET",
        subtitle: "Vessel Row — 03:38",
        environment: .street,
        railPoints: [
            SIMD3(0, 0, -6), SIMD3(0, 0, 10), SIMD3(-2, 0, 26), SIMD3(-2, 0, 42),
            SIMD3(3, 0, 56), SIMD3(4, 0, 72), SIMD3(0, 0, 88), SIMD3(-4, 0, 104),
            SIMD3(-3, 0, 120), SIMD3(0, 0, 134), SIMD3(0, 0, 146)
        ],
        travelSpeed: 2.8,
        encounters: [
            EncounterDef(
                id: "s1", triggerDistance: 16, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.4, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 25, lateral: -3.0),
                        SpawnDef(kind: .runner, railDistance: 26, lateral: 3.0, delay: 0.5),
                        SpawnDef(kind: .shambler, railDistance: 27, lateral: -6.0, delay: 1.0),
                        SpawnDef(kind: .shambler, railDistance: 28, lateral: 6.0, delay: 1.4)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .spitter, railDistance: 36, lateral: -5.0),
                        SpawnDef(kind: .runner, railDistance: 30, lateral: 0, delay: 1.0),
                        SpawnDef(kind: .crawler, railDistance: 29, lateral: 4.0, delay: 1.6)
                    ])
                ],
                banner: "ACID — SHOOT IT DOWN"),
            EncounterDef(
                id: "s2", triggerDistance: 44, gaze: .offset(yaw: 26, pitch: 8),
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 52, lateral: 5.0, height: 3.6, entrance: .dropFromAbove),
                        SpawnDef(kind: .runner, railDistance: 53, lateral: 6.0, delay: 0.8, entrance: .burstThrough),
                        SpawnDef(kind: .crawler, railDistance: 54, lateral: 2.0, delay: 1.4),
                        SpawnDef(kind: .runner, railDistance: 55, lateral: -3.0, delay: 2.0)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .brute, railDistance: 58, lateral: 0),
                        SpawnDef(kind: .spitter, railDistance: 66, lateral: 6.0, delay: 0.6),
                        SpawnDef(kind: .runner, railDistance: 57, lateral: -5.0, delay: 1.4),
                        SpawnDef(kind: .runner, railDistance: 57, lateral: 5.0, delay: 1.8)
                    ])
                ]),
            EncounterDef(
                id: "s3", triggerDistance: 74, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .crawler, railDistance: 82, lateral: -2.0),
                        SpawnDef(kind: .crawler, railDistance: 82, lateral: 2.0, delay: 0.4),
                        SpawnDef(kind: .crawler, railDistance: 83, lateral: -5.0, delay: 0.8),
                        SpawnDef(kind: .runner, railDistance: 85, lateral: 0, delay: 1.4),
                        SpawnDef(kind: .spitter, railDistance: 92, lateral: -6.0, delay: 1.8)
                    ])
                ],
                banner: "CIVILIAN — HOLD YOUR FIRE",
                survivor: SurvivorDef(railDistance: 86, lateral: 3.0, rescueBonus: 3000)),
            EncounterDef(
                id: "s4", triggerDistance: 96, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 104, lateral: -3.0),
                        SpawnDef(kind: .runner, railDistance: 104, lateral: 3.0, delay: 0.4),
                        SpawnDef(kind: .shambler, railDistance: 106, lateral: -6.0, delay: 0.9),
                        SpawnDef(kind: .shambler, railDistance: 106, lateral: 6.0, delay: 1.3),
                        SpawnDef(kind: .spitter, railDistance: 114, lateral: 0, delay: 1.8)
                    ]),
                    WaveDef(startDelay: 0.6, spawns: [
                        SpawnDef(kind: .brute, railDistance: 108, lateral: -3.0),
                        SpawnDef(kind: .brute, railDistance: 108, lateral: 3.0, delay: 1.0),
                        SpawnDef(kind: .crawler, railDistance: 107, lateral: 0, delay: 2.0),
                        SpawnDef(kind: .runner, railDistance: 109, lateral: 6.0, delay: 2.6)
                    ])
                ]),
            EncounterDef(
                id: "s5", triggerDistance: 126, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.4, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 136, lateral: -2.0),
                        SpawnDef(kind: .runner, railDistance: 136, lateral: 2.0, delay: 0.3),
                        SpawnDef(kind: .runner, railDistance: 137, lateral: -5.0, delay: 0.7),
                        SpawnDef(kind: .runner, railDistance: 137, lateral: 5.0, delay: 1.0),
                        SpawnDef(kind: .spitter, railDistance: 143, lateral: -4.0, delay: 1.5),
                        SpawnDef(kind: .spitter, railDistance: 143, lateral: 4.0, delay: 1.9),
                        SpawnDef(kind: .brute, railDistance: 140, lateral: 0, delay: 3.0)
                    ])
                ],
                banner: "THE BARRICADE IS AHEAD"),
        ],
        ambushes: [
            SpawnDef(kind: .shambler, railDistance: 34, lateral: 7.0),
            SpawnDef(kind: .crawler, railDistance: 62, lateral: -6.5),
            SpawnDef(kind: .shambler, railDistance: 68, lateral: 7.5),
            SpawnDef(kind: .runner, railDistance: 118, lateral: -6.0),
            SpawnDef(kind: .crawler, railDistance: 122, lateral: 6.0)
        ],
        briefing: "Vessel Row is burning and the cordon has already fallen back twice. Push through to the barricade. Do not stop moving.",
        seed: 3003)

    // MARK: 4 — Sublevel Seven

    static let lab = LevelDef(
        index: 3,
        name: "PATIENT ZERO",
        subtitle: "Sublevel Seven — 04:26",
        environment: .lab,
        railPoints: [
            SIMD3(0, 0, -4), SIMD3(0, 0, 12), SIMD3(0, 0, 26),
            SIMD3(-7, 0, 34), SIMD3(-16, 0, 36), SIMD3(-26, 0, 34),
            SIMD3(-32, 0, 26), SIMD3(-32, 0, 12), SIMD3(-28, 0, 0),
            SIMD3(-18, 0, -6), SIMD3(-6, 0, -8), SIMD3(6, 0, -8)
        ],
        travelSpeed: 2.9,
        encounters: [
            EncounterDef(
                id: "l1", triggerDistance: 14, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 22, lateral: -2.0, entrance: .burstThrough),
                        SpawnDef(kind: .runner, railDistance: 22, lateral: 2.0, delay: 0.4, entrance: .burstThrough),
                        SpawnDef(kind: .crawler, railDistance: 24, lateral: 0, delay: 1.0),
                        SpawnDef(kind: .shambler, railDistance: 25, lateral: -4.0, delay: 1.5)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .spitter, railDistance: 32, lateral: 3.0),
                        SpawnDef(kind: .runner, railDistance: 26, lateral: -3.0, delay: 0.8),
                        SpawnDef(kind: .runner, railDistance: 26, lateral: 3.0, delay: 1.1),
                        SpawnDef(kind: .crawler, railDistance: 27, lateral: 0, delay: 1.8)
                    ])
                ],
                banner: "CONTAINMENT FAILED"),
            EncounterDef(
                id: "l2", triggerDistance: 38, gaze: .offset(yaw: -30, pitch: 0),
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .brute, railDistance: 46, lateral: -1.0),
                        SpawnDef(kind: .crawler, railDistance: 45, lateral: -4.0, delay: 0.7),
                        SpawnDef(kind: .crawler, railDistance: 45, lateral: 3.5, delay: 1.0),
                        SpawnDef(kind: .runner, railDistance: 48, lateral: 0, delay: 1.7)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .spitter, railDistance: 56, lateral: -4.0),
                        SpawnDef(kind: .spitter, railDistance: 56, lateral: 4.0, delay: 0.5),
                        SpawnDef(kind: .runner, railDistance: 50, lateral: -3.0, delay: 1.1),
                        SpawnDef(kind: .runner, railDistance: 50, lateral: 3.0, delay: 1.4),
                        SpawnDef(kind: .crawler, railDistance: 51, lateral: 0, delay: 2.1)
                    ])
                ]),
            EncounterDef(
                id: "l3", triggerDistance: 62, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .crawler, railDistance: 70, lateral: -2.0, entrance: .riseFromGround),
                        SpawnDef(kind: .crawler, railDistance: 70, lateral: 2.0, delay: 0.3, entrance: .riseFromGround),
                        SpawnDef(kind: .crawler, railDistance: 71, lateral: -5.0, delay: 0.6),
                        SpawnDef(kind: .crawler, railDistance: 71, lateral: 5.0, delay: 0.9),
                        SpawnDef(kind: .runner, railDistance: 73, lateral: 0, delay: 1.6)
                    ]),
                    WaveDef(startDelay: 0.4, spawns: [
                        SpawnDef(kind: .brute, railDistance: 74, lateral: -2.5),
                        SpawnDef(kind: .brute, railDistance: 74, lateral: 2.5, delay: 0.9),
                        SpawnDef(kind: .spitter, railDistance: 82, lateral: 0, delay: 1.5),
                        SpawnDef(kind: .runner, railDistance: 76, lateral: -5.0, delay: 2.2),
                        SpawnDef(kind: .runner, railDistance: 76, lateral: 5.0, delay: 2.5)
                    ])
                ],
                banner: "SURVIVOR IN THE LAB",
                survivor: SurvivorDef(railDistance: 78, lateral: 4.0, rescueBonus: 3500, healthReward: 25)),
            EncounterDef(
                id: "l4", triggerDistance: 90, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 98, lateral: -2.0),
                        SpawnDef(kind: .runner, railDistance: 98, lateral: 2.0, delay: 0.5),
                        SpawnDef(kind: .crawler, railDistance: 100, lateral: 0, delay: 1.4),
                        SpawnDef(kind: .spitter, railDistance: 106, lateral: -3.0, delay: 2.2)
                    ]),
                    WaveDef(startDelay: 0.9, spawns: [
                        SpawnDef(kind: .brute, railDistance: 102, lateral: -3.0),
                        SpawnDef(kind: .brute, railDistance: 101, lateral: 4.0, delay: 2.6),
                        SpawnDef(kind: .crawler, railDistance: 103, lateral: -2.0, delay: 4.0),
                        SpawnDef(kind: .crawler, railDistance: 103, lateral: 2.0, delay: 4.6)
                    ])
                ],
                banner: "THREE OF THEM"),
            EncounterDef(
                id: "l5", triggerDistance: 118, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .crawler, railDistance: 126, lateral: -3.0),
                        SpawnDef(kind: .crawler, railDistance: 126, lateral: 3.0, delay: 0.4),
                        SpawnDef(kind: .runner, railDistance: 128, lateral: -1.5, delay: 1.0),
                        SpawnDef(kind: .runner, railDistance: 128, lateral: 1.5, delay: 1.4),
                        SpawnDef(kind: .spitter, railDistance: 134, lateral: -5.0, delay: 2.2)
                    ]),
                    WaveDef(startDelay: 1.0, spawns: [
                        SpawnDef(kind: .brute, railDistance: 130, lateral: 0),
                        SpawnDef(kind: .runner, railDistance: 129, lateral: -6.0, delay: 1.8),
                        SpawnDef(kind: .runner, railDistance: 129, lateral: 6.0, delay: 2.2)
                    ])
                ],
                banner: "THE LIFT IS AHEAD"),
        ],
        ambushes: [
            SpawnDef(kind: .runner, railDistance: 30, lateral: 5.0, entrance: .burstThrough),
            SpawnDef(kind: .crawler, railDistance: 56, lateral: -5.5),
            SpawnDef(kind: .runner, railDistance: 86, lateral: 5.5, entrance: .burstThrough),
            SpawnDef(kind: .crawler, railDistance: 110, lateral: -5.0),
            SpawnDef(kind: .shambler, railDistance: 114, lateral: 5.5)
        ],
        briefing: "The manor cellar runs into something the maps do not show. Seven levels down, someone was growing this on purpose. Find the source.",
        seed: 4004)

    // MARK: 5 — The Spire

    static let spire = LevelDef(
        index: 4,
        name: "VESPERS",
        subtitle: "Ashwood Spire — 05:03",
        environment: .spire,
        railPoints: [
            SIMD3(0, 0, -6), SIMD3(0, 0, 10), SIMD3(0, 0, 26), SIMD3(0, 0, 42),
            SIMD3(-4, 1.2, 56), SIMD3(-4, 3.0, 68), SIMD3(0, 4.5, 80),
            SIMD3(4, 6.0, 92), SIMD3(2, 7.5, 106), SIMD3(0, 8.5, 120), SIMD3(0, 8.5, 132)
        ],
        travelSpeed: 2.9,
        encounters: [
            EncounterDef(
                id: "p1", triggerDistance: 16, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 25, lateral: -2.5),
                        SpawnDef(kind: .runner, railDistance: 25, lateral: 2.5, delay: 0.3),
                        SpawnDef(kind: .shambler, railDistance: 27, lateral: -6.0, delay: 0.8),
                        SpawnDef(kind: .shambler, railDistance: 27, lateral: 6.0, delay: 1.1),
                        SpawnDef(kind: .crawler, railDistance: 28, lateral: 0, delay: 1.7)
                    ]),
                    WaveDef(startDelay: 0.5, spawns: [
                        SpawnDef(kind: .spitter, railDistance: 36, lateral: -5.0),
                        SpawnDef(kind: .runner, railDistance: 29, lateral: -3.0, delay: 1.0),
                        SpawnDef(kind: .runner, railDistance: 29, lateral: 3.0, delay: 1.5),
                        SpawnDef(kind: .brute, railDistance: 31, lateral: 0, delay: 3.0)
                    ])
                ],
                banner: "THE NAVE IS FULL"),
            EncounterDef(
                id: "p2", triggerDistance: 46, gaze: .offset(yaw: 24, pitch: 12),
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .shambler, railDistance: 54, lateral: 5.0, height: 4.2, entrance: .dropFromAbove),
                        SpawnDef(kind: .shambler, railDistance: 55, lateral: -5.0, height: 4.2, delay: 0.5, entrance: .dropFromAbove),
                        SpawnDef(kind: .runner, railDistance: 56, lateral: 0, delay: 1.1),
                        SpawnDef(kind: .crawler, railDistance: 57, lateral: 3.0, delay: 1.6),
                        SpawnDef(kind: .crawler, railDistance: 57, lateral: -3.0, delay: 1.9)
                    ]),
                    WaveDef(startDelay: 0.4, spawns: [
                        SpawnDef(kind: .brute, railDistance: 60, lateral: -2.5),
                        SpawnDef(kind: .brute, railDistance: 60, lateral: 2.5, delay: 0.9),
                        SpawnDef(kind: .spitter, railDistance: 68, lateral: 0, delay: 1.5),
                        SpawnDef(kind: .runner, railDistance: 61, lateral: -5.5, delay: 2.1),
                        SpawnDef(kind: .runner, railDistance: 61, lateral: 5.5, delay: 2.4)
                    ])
                ]),
            EncounterDef(
                id: "p3", triggerDistance: 74, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 82, lateral: -2.0),
                        SpawnDef(kind: .runner, railDistance: 82, lateral: 2.0, delay: 0.3),
                        SpawnDef(kind: .crawler, railDistance: 83, lateral: -4.5, delay: 0.6),
                        SpawnDef(kind: .crawler, railDistance: 83, lateral: 4.5, delay: 0.9),
                        SpawnDef(kind: .spitter, railDistance: 90, lateral: -3.0, delay: 1.5),
                        SpawnDef(kind: .spitter, railDistance: 90, lateral: 3.0, delay: 1.8)
                    ])
                ],
                banner: "LAST CIVILIAN — HOLD YOUR FIRE",
                survivor: SurvivorDef(railDistance: 86, lateral: 0, rescueBonus: 4000, healthReward: 30)),
            EncounterDef(
                id: "p4", triggerDistance: 98, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 0.3, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 107, lateral: 0),
                        SpawnDef(kind: .runner, railDistance: 108, lateral: -6.0, delay: 0.6),
                        SpawnDef(kind: .runner, railDistance: 108, lateral: 6.0, delay: 1.0),
                        SpawnDef(kind: .crawler, railDistance: 109, lateral: -2.0, delay: 1.8),
                        SpawnDef(kind: .crawler, railDistance: 109, lateral: 2.0, delay: 2.2)
                    ]),
                    WaveDef(startDelay: 0.8, spawns: [
                        SpawnDef(kind: .brute, railDistance: 106, lateral: -3.0),
                        SpawnDef(kind: .brute, railDistance: 106, lateral: 3.0, delay: 2.2),
                        SpawnDef(kind: .spitter, railDistance: 114, lateral: 0, delay: 3.0)
                    ])
                ],
                banner: "HOLD THE STAIR"),
            EncounterDef(
                id: "boss", triggerDistance: 126, gaze: .forward,
                waves: [
                    WaveDef(startDelay: 1.6, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .warden, railDistance: 140, lateral: 0, entrance: .lurch)
                    ]),
                    // Adds trickle in while the Warden recovers between phases.
                    WaveDef(startDelay: 20, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 136, lateral: -6.0),
                        SpawnDef(kind: .runner, railDistance: 136, lateral: 6.0, delay: 1.2)
                    ]),
                    WaveDef(startDelay: 26, afterPreviousCleared: false, spawns: [
                        SpawnDef(kind: .runner, railDistance: 137, lateral: -7.0),
                        SpawnDef(kind: .crawler, railDistance: 135, lateral: 0, delay: 1.4),
                        SpawnDef(kind: .spitter, railDistance: 143, lateral: 5.0, delay: 2.4)
                    ])
                ],
                banner: "THE WARDEN",
                failsafeTimeout: 300),
        ],
        ambushes: [
            SpawnDef(kind: .crawler, railDistance: 34, lateral: -6.0),
            SpawnDef(kind: .shambler, railDistance: 40, lateral: 6.5),
            SpawnDef(kind: .runner, railDistance: 66, lateral: -5.5),
            SpawnDef(kind: .crawler, railDistance: 94, lateral: 5.5),
            SpawnDef(kind: .shambler, railDistance: 118, lateral: -6.0),
            SpawnDef(kind: .shambler, railDistance: 120, lateral: 6.0)
        ],
        briefing: "Everything in Sublevel Seven pointed up here. Whatever the Ashwoods were keeping, it is awake, it is in the spire, and it has been waiting for someone to climb.",
        seed: 5005)
}
