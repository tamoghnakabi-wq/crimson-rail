import Foundation
import SwiftUI
import AppKit

/// Bridges the game's state into SwiftUI. The game loop runs on SceneKit's
/// render callback, so every mutation here is bounced to the main actor.
final class MenuModel: ObservableObject {
    @Published var mode: Game.Mode = .mainMenu
    @Published var settings: Settings
    @Published var save: SaveData
    @Published var selectedLevel: Int = 0
    @Published var lastResult: RunResult?
    @Published var lastLevelIndex: Int = 0

    weak var game: Game?

    init(settings: Settings, save: SaveData) {
        self.settings = settings
        self.save = save
    }

    func apply() { game?.updateSettings(settings) }
}

// MARK: - Shared style

private enum Style {
    static let ink = Color(red: 0.92, green: 0.89, blue: 0.85)
    static let dim = Color(red: 0.55, green: 0.53, blue: 0.51)
    static let accent = Color(red: 0.84, green: 0.16, blue: 0.12)
    static let panel = Color(red: 0.05, green: 0.045, blue: 0.05)
    static let mono = "Menlo"
}

private struct MenuButton: View {
    let title: String
    var subtitle: String? = nil
    var enabled: Bool = true
    var destructive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { if enabled { action() } }) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(hovering && enabled ? (destructive ? Style.accent : Style.ink) : Color.clear)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.custom(Style.mono, size: 17).weight(.semibold))
                        .foregroundColor(enabled ? (destructive ? Style.accent : Style.ink) : Style.dim.opacity(0.5))
                    if let subtitle {
                        Text(subtitle)
                            .font(.custom(Style.mono, size: 11))
                            .foregroundColor(Style.dim)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(hovering && enabled ? Color.white.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(!enabled)
    }
}

private struct Heading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.custom(Style.mono, size: 11).weight(.bold))
            .tracking(3)
            .foregroundColor(Style.dim)
    }
}

/// Full-bleed dark scrim so menus stay legible over a lit scene.
private struct Scrim<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.93), Color.black.opacity(0.80)],
                           startPoint: .leading, endPoint: .trailing)
            content
        }
        .ignoresSafeArea()
    }
}

// MARK: - Root

struct MenuRoot: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        Group {
            switch model.mode {
            case .mainMenu: MainMenuView(model: model)
            case .levelSelect: LevelSelectView(model: model)
            case .settings: SettingsView(model: model)
            case .briefing(let level): BriefingView(model: model, levelIndex: level)
            case .paused: PauseView(model: model)
            case .results: ResultsView(model: model)
            case .credits: CreditsView(model: model)
            case .playing: EmptyView()
            }
        }
    }
}

// MARK: - Main menu

private struct MainMenuView: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        Scrim {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 70)
                    Text("CRIMSON")
                        .font(.custom(Style.mono, size: 58).weight(.black))
                        .tracking(8)
                        .foregroundColor(Style.ink)
                    Text("RAIL")
                        .font(.custom(Style.mono, size: 58).weight(.black))
                        .tracking(28)
                        .foregroundColor(Style.accent)
                    Rectangle().fill(Style.accent).frame(width: 220, height: 2).padding(.top, 10)
                    Text("A LIGHT-GUN NIGHTMARE IN FIVE PARTS")
                        .font(.custom(Style.mono, size: 11))
                        .tracking(2)
                        .foregroundColor(Style.dim)
                        .padding(.top, 12)

                    Spacer().frame(height: 46)

                    VStack(alignment: .leading, spacing: 2) {
                        MenuButton(title: continueTitle,
                                   subtitle: LevelCatalog.level(model.save.highestUnlocked).subtitle) {
                            model.selectedLevel = model.save.highestUnlocked
                            model.game?.setMode(.briefing(level: model.save.highestUnlocked))
                        }
                        MenuButton(title: "MISSION SELECT",
                                   subtitle: "\(model.save.highestUnlocked + 1) of \(LevelCatalog.count) unlocked") {
                            model.game?.setMode(.levelSelect)
                        }
                        MenuButton(title: "SETTINGS", subtitle: "Graphics, audio, difficulty") {
                            model.game?.setMode(.settings)
                        }
                        MenuButton(title: "QUIT", destructive: true) {
                            NSApp.terminate(nil)
                        }
                    }
                    Spacer()
                    statsFooter
                        .padding(.bottom, 40)
                }
                .padding(.leading, 76)
                .frame(maxWidth: 560, alignment: .leading)
                Spacer()
            }
        }
    }

    private var continueTitle: String {
        model.save.highestUnlocked == 0 && model.save.levels[0].attempts == 0 ? "BEGIN" : "CONTINUE"
    }

    private var statsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Heading(text: "SERVICE RECORD")
            HStack(spacing: 26) {
                stat("KILLS", "\(model.save.totalKills)")
                stat("ACCURACY", String(format: "%.0f%%", model.save.lifetimeAccuracy * 100))
                stat("HEADSHOTS", "\(model.save.headshots)")
                stat("SAVED", "\(model.save.survivorsSaved)")
            }
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.custom(Style.mono, size: 16).weight(.bold)).foregroundColor(Style.ink)
            Text(k).font(.custom(Style.mono, size: 9)).tracking(1).foregroundColor(Style.dim)
        }
    }
}

// MARK: - Level select

private struct LevelSelectView: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        Scrim {
            VStack(alignment: .leading, spacing: 0) {
                Heading(text: "MISSION SELECT").padding(.top, 54)
                Text("CHOOSE YOUR ENTRY POINT")
                    .font(.custom(Style.mono, size: 26).weight(.bold))
                    .foregroundColor(Style.ink)
                    .padding(.top, 6)

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(0..<LevelCatalog.count, id: \.self) { i in
                            levelCard(i)
                        }
                    }
                    .padding(.top, 22)
                }
                .frame(maxHeight: 460)

                MenuButton(title: "BACK") { model.game?.setMode(.mainMenu) }
                    .padding(.top, 14)
                Spacer()
            }
            .padding(.horizontal, 76)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func levelCard(_ i: Int) -> some View {
        let def = LevelCatalog.level(i)
        let rec = model.save.levels.indices.contains(i) ? model.save.levels[i] : LevelRecord()
        let unlocked = model.save.isUnlocked(i)
        return Button {
            guard unlocked else { return }
            model.selectedLevel = i
            model.game?.setMode(.briefing(level: i))
        } label: {
            HStack(spacing: 16) {
                Text(String(format: "%02d", i + 1))
                    .font(.custom(Style.mono, size: 30).weight(.black))
                    .foregroundColor(unlocked ? Style.accent : Style.dim.opacity(0.4))
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(unlocked ? def.name : "— LOCKED —")
                        .font(.custom(Style.mono, size: 17).weight(.bold))
                        .foregroundColor(unlocked ? Style.ink : Style.dim.opacity(0.6))
                    Text(unlocked ? def.subtitle : "Clear the previous mission to unlock")
                        .font(.custom(Style.mono, size: 11))
                        .foregroundColor(Style.dim)
                }
                Spacer()
                if unlocked && rec.completed {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(rec.bestRank?.rawValue ?? "-")
                            .font(.custom(Style.mono, size: 24).weight(.black))
                            .foregroundColor(rankColor(rec.bestRank))
                        Text("\(rec.bestScore)")
                            .font(.custom(Style.mono, size: 11))
                            .foregroundColor(Style.dim)
                    }
                }
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(unlocked ? 0.045 : 0.015))
            .overlay(Rectangle().fill(unlocked ? Style.accent : Style.dim.opacity(0.3)).frame(width: 2),
                     alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
    }

    private func rankColor(_ r: Rank?) -> Color {
        switch r {
        case .s: return Color(red: 1.0, green: 0.82, blue: 0.25)
        case .a: return Color(red: 0.55, green: 0.90, blue: 0.55)
        case .b: return Color(red: 0.55, green: 0.75, blue: 0.95)
        default: return Style.dim
        }
    }
}

// MARK: - Briefing

private struct BriefingView: View {
    @ObservedObject var model: MenuModel
    let levelIndex: Int

    var body: some View {
        let def = LevelCatalog.level(levelIndex)
        Scrim {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Heading(text: String(format: "MISSION %02d", levelIndex + 1))
                Text(def.name)
                    .font(.custom(Style.mono, size: 44).weight(.black))
                    .foregroundColor(Style.ink)
                    .padding(.top, 4)
                Text(def.subtitle)
                    .font(.custom(Style.mono, size: 13))
                    .foregroundColor(Style.accent)
                    .padding(.top, 2)
                Rectangle().fill(Style.dim.opacity(0.4)).frame(height: 1).padding(.vertical, 18)
                Text(def.briefing)
                    .font(.custom(Style.mono, size: 13))
                    .foregroundColor(Style.dim)
                    .lineSpacing(6)
                    .frame(maxWidth: 520, alignment: .leading)

                HStack(spacing: 30) {
                    briefStat("THREATS", "\(def.totalThreats)")
                    briefStat("ENCOUNTERS", "\(def.encounters.count)")
                    briefStat("DIFFICULTY", model.settings.gameplay.difficulty.displayName.uppercased())
                }
                .padding(.top, 22)

                VStack(alignment: .leading, spacing: 2) {
                    MenuButton(title: "DEPLOY") { model.game?.startLevel(levelIndex) }
                    MenuButton(title: "BACK") { model.game?.setMode(.levelSelect) }
                }
                .padding(.top, 26)

                Text("MOUSE  aim    LEFT CLICK  fire    R / RIGHT CLICK  reload    P / ESC  pause")
                    .font(.custom(Style.mono, size: 10))
                    .tracking(1)
                    .foregroundColor(Style.dim.opacity(0.75))
                    .padding(.top, 26)
                Spacer()
            }
            .padding(.leading, 76)
            .frame(maxWidth: 700, alignment: .leading)
        }
    }

    private func briefStat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.custom(Style.mono, size: 19).weight(.bold)).foregroundColor(Style.ink)
            Text(k).font(.custom(Style.mono, size: 9)).tracking(1.5).foregroundColor(Style.dim)
        }
    }
}

// MARK: - Pause

private struct PauseView: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        Scrim {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Heading(text: "PAUSED")
                Text("HOLDING POSITION")
                    .font(.custom(Style.mono, size: 34).weight(.black))
                    .foregroundColor(Style.ink)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    MenuButton(title: "RESUME") { model.game?.setMode(.playing) }
                    MenuButton(title: "RESTART MISSION") { model.game?.restartLevel() }
                    MenuButton(title: "SETTINGS") { model.game?.setMode(.settings) }
                    MenuButton(title: "ABANDON", destructive: true) { model.game?.abandonRun() }
                }
                .padding(.top, 26)
                Spacer()
            }
            .padding(.leading, 76)
            .frame(maxWidth: 520, alignment: .leading)
        }
    }
}

// MARK: - Results

private struct ResultsView: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        let r = model.lastResult ?? RunResult()
        let won = r.won
        let hasNext = model.lastLevelIndex + 1 < LevelCatalog.count
        Scrim {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Heading(text: won ? "MISSION COMPLETE" : "MISSION FAILED")
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    Text(won ? LevelCatalog.level(model.lastLevelIndex).name : "YOU DIED")
                        .font(.custom(Style.mono, size: 40).weight(.black))
                        .foregroundColor(won ? Style.ink : Style.accent)
                    if won {
                        Text(r.rank.rawValue)
                            .font(.custom(Style.mono, size: 64).weight(.black))
                            .foregroundColor(rankColor(r.rank))
                    }
                }
                .padding(.top, 2)

                Rectangle().fill(Style.dim.opacity(0.4)).frame(height: 1).padding(.vertical, 20)

                HStack(alignment: .top, spacing: 46) {
                    VStack(alignment: .leading, spacing: 9) {
                        row("SCORE", "\(r.score)")
                        row("KILLS", "\(r.kills) / \(r.totalThreats)")
                        row("HEADSHOTS", "\(r.headshots)")
                        row("BEST COMBO", "x\(r.bestCombo)")
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        row("ACCURACY", String(format: "%.1f%%  (%d/%d)", r.accuracy * 100, r.hits, r.shots))
                        row("HEALTH LEFT", String(format: "%.0f%%", r.healthFraction * 100))
                        row("CIVILIANS SAVED", "\(r.survivorsSaved)")
                        row("CIVILIANS LOST", "\(r.survivorsLost)", warn: r.survivorsLost > 0)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    if won && hasNext {
                        MenuButton(title: "NEXT MISSION",
                                   subtitle: LevelCatalog.level(model.lastLevelIndex + 1).name) {
                            model.game?.setMode(.briefing(level: model.lastLevelIndex + 1))
                        }
                    }
                    if won && !hasNext {
                        MenuButton(title: "VIEW CREDITS") { model.game?.setMode(.credits) }
                    }
                    MenuButton(title: won ? "REPLAY MISSION" : "TRY AGAIN") { model.game?.restartLevel() }
                    MenuButton(title: "MAIN MENU") { model.game?.abandonRun() }
                }
                .padding(.top, 26)
                Spacer()
            }
            .padding(.leading, 76)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String, warn: Bool = false) -> some View {
        HStack(spacing: 14) {
            Text(k).font(.custom(Style.mono, size: 10)).tracking(1.5)
                .foregroundColor(Style.dim).frame(width: 128, alignment: .leading)
            Text(v).font(.custom(Style.mono, size: 15).weight(.semibold))
                .foregroundColor(warn ? Style.accent : Style.ink)
        }
    }

    private func rankColor(_ r: Rank) -> Color {
        switch r {
        case .s: return Color(red: 1.0, green: 0.82, blue: 0.25)
        case .a: return Color(red: 0.55, green: 0.90, blue: 0.55)
        case .b: return Color(red: 0.55, green: 0.75, blue: 0.95)
        case .c: return Style.ink
        case .d: return Style.dim
        }
    }
}

// MARK: - Credits

private struct CreditsView: View {
    @ObservedObject var model: MenuModel
    var body: some View {
        Scrim {
            VStack(alignment: .leading, spacing: 14) {
                Spacer()
                Text("CRIMSON RAIL")
                    .font(.custom(Style.mono, size: 40).weight(.black))
                    .tracking(6)
                    .foregroundColor(Style.ink)
                Text("The Ashwood file is closed.")
                    .font(.custom(Style.mono, size: 14)).foregroundColor(Style.accent)
                Text("""
                Every model, texture, sound and piece of music in this game is
                generated in code at launch. There are no asset files.

                Built with Swift, SceneKit, Metal and AVAudioEngine.
                """)
                .font(.custom(Style.mono, size: 12))
                .foregroundColor(Style.dim)
                .lineSpacing(5)
                MenuButton(title: "MAIN MENU") { model.game?.abandonRun() }.padding(.top, 16)
                Spacer()
            }
            .padding(.leading, 76)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        Scrim {
            VStack(alignment: .leading, spacing: 0) {
                Heading(text: "SETTINGS").padding(.top, 46)
                Text("CONFIGURATION")
                    .font(.custom(Style.mono, size: 28).weight(.bold))
                    .foregroundColor(Style.ink)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        graphicsSection
                        audioSection
                        gameplaySection
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                }
                .frame(maxHeight: 470)

                MenuButton(title: "BACK") {
                    model.apply()
                    model.game?.setMode(model.game?.playingLevelIndex != nil ? .paused : .mainMenu)
                }
                .padding(.top, 10)
                Spacer()
            }
            .padding(.horizontal, 76)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private var graphicsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Heading(text: "GRAPHICS")
            HStack(spacing: 8) {
                ForEach(QualityPreset.allCases, id: \.self) { p in
                    Button {
                        model.settings.graphics = .forPreset(p)
                        model.apply()
                    } label: {
                        Text(p.displayName.uppercased())
                            .font(.custom(Style.mono, size: 12).weight(.bold))
                            .tracking(1)
                            .padding(.vertical, 8).padding(.horizontal, 16)
                            .background(model.settings.graphics.preset == p ? Style.accent : Color.white.opacity(0.06))
                            .foregroundColor(model.settings.graphics.preset == p ? .white : Style.ink)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(model.settings.graphics.preset.blurb)
                .font(.custom(Style.mono, size: 11)).foregroundColor(Style.dim)
            Text("Preset changes apply when the next mission loads.")
                .font(.custom(Style.mono, size: 10)).foregroundColor(Style.dim.opacity(0.8))

            toggle("Shadows", $model.settings.graphics.shadowsEnabled)
            toggle("Ambient occlusion", $model.settings.graphics.ambientOcclusion)
            toggle("Bloom", $model.settings.graphics.bloom)
            toggle("Film grain", $model.settings.graphics.filmGrain)
            toggle("Motion blur", $model.settings.graphics.motionBlur)
            slider("Render scale", $model.settings.graphics.renderScale, 0.6...1.0, format: "%.0f%%", scale: 100)
            slider("Particles", $model.settings.graphics.particleBudget, 0...2.0, format: "%.0f%%", scale: 100)
            slider("Draw distance", $model.settings.graphics.drawDistance, 60...200, format: "%.0f m")
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Heading(text: "AUDIO")
            slider("Master", $model.settings.audio.master, 0...1, format: "%.0f%%", scale: 100)
            slider("Effects", $model.settings.audio.sfx, 0...1, format: "%.0f%%", scale: 100)
            slider("Music", $model.settings.audio.music, 0...1, format: "%.0f%%", scale: 100)
            slider("Ambience", $model.settings.audio.ambience, 0...1, format: "%.0f%%", scale: 100)
        }
    }

    private var gameplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Heading(text: "GAMEPLAY")
            HStack(spacing: 8) {
                ForEach(Difficulty.allCases, id: \.self) { d in
                    Button {
                        model.settings.gameplay.difficulty = d
                        model.apply()
                    } label: {
                        Text(d.displayName.uppercased())
                            .font(.custom(Style.mono, size: 12).weight(.bold))
                            .tracking(1)
                            .padding(.vertical, 8).padding(.horizontal, 16)
                            .background(model.settings.gameplay.difficulty == d ? Style.accent : Color.white.opacity(0.06))
                            .foregroundColor(model.settings.gameplay.difficulty == d ? .white : Style.ink)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(model.settings.gameplay.difficulty.blurb)
                .font(.custom(Style.mono, size: 11)).foregroundColor(Style.dim)

            HStack(spacing: 8) {
                Text("CROSSHAIR").font(.custom(Style.mono, size: 10)).tracking(1.5)
                    .foregroundColor(Style.dim).frame(width: 150, alignment: .leading)
                ForEach(CrosshairStyle.allCases, id: \.self) { c in
                    Button {
                        model.settings.gameplay.crosshair = c
                        model.apply()
                    } label: {
                        Text(c.displayName.uppercased())
                            .font(.custom(Style.mono, size: 11))
                            .padding(.vertical, 6).padding(.horizontal, 12)
                            .background(model.settings.gameplay.crosshair == c ? Style.accent : Color.white.opacity(0.06))
                            .foregroundColor(model.settings.gameplay.crosshair == c ? .white : Style.ink)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            slider("Mouse sensitivity", $model.settings.gameplay.lookSensitivity, 0.25...3.0, format: "%.2fx")
            toggle("Invert look Y", $model.settings.gameplay.invertLookY)
            slider("Crosshair size", $model.settings.gameplay.crosshairScale, 0.6...2.0, format: "%.2fx")
            slider("Camera sway", $model.settings.gameplay.cameraSway, 0...1.5, format: "%.0f%%", scale: 100)
            slider("Screen shake", $model.settings.gameplay.screenShake, 0...1.5, format: "%.0f%%", scale: 100)
            slider("Blood", $model.settings.gameplay.goreLevel, 0...1.5, format: "%.0f%%", scale: 100)
            toggle("Damage numbers", $model.settings.gameplay.showDamageNumbers)
            toggle("Start in full screen", $model.settings.gameplay.fullscreenOnLaunch)
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.custom(Style.mono, size: 10)).tracking(1.5)
                .foregroundColor(Style.dim).frame(width: 150, alignment: .leading)
            Toggle("", isOn: Binding(get: { binding.wrappedValue },
                                     set: { binding.wrappedValue = $0; model.apply() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Style.accent)
            Spacer()
        }
    }

    private func slider(_ title: String, _ binding: Binding<Float>,
                        _ range: ClosedRange<Float>, format: String, scale: Float = 1) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.custom(Style.mono, size: 10)).tracking(1.5)
                .foregroundColor(Style.dim).frame(width: 150, alignment: .leading)
            Slider(value: Binding(get: { binding.wrappedValue },
                                  set: { binding.wrappedValue = $0; model.apply() }),
                   in: range)
                .frame(width: 240)
                .tint(Style.accent)
            Text(String(format: format, binding.wrappedValue * scale))
                .font(.custom(Style.mono, size: 11)).foregroundColor(Style.ink)
                .frame(width: 62, alignment: .leading)
            Spacer()
        }
    }
}
