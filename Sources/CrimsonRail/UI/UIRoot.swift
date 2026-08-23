import Foundation
import AppKit
import SwiftUI
import SceneKit

/// Owns everything drawn over the 3D view: the SpriteKit HUD and the SwiftUI
/// menu layer.
enum UIRoot {
    private static weak var hostingView: NSView?

    static func install(in view: GameView, game: Game) {
        // HUD: a SceneKit overlay, so it is composited inside the render loop and
        // the crosshair never trails the frame it belongs to.
        game.hud.size = view.bounds.size
        view.overlaySKScene = game.hud
        game.hud.isHidden = true

        // Menus: SwiftUI in a hosting view laid over the whole window.
        let host = NSHostingView(rootView: MenuRoot(model: game.menuModel))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        hostingView = host

        // An NSHostingView reports itself as the hit-test result for every point
        // inside its bounds, so leaving it in place would swallow every click
        // meant for the game. Hiding it removes it from hit testing entirely.
        // `--play N` boots straight into a level. Useful for testing a specific
        // level without clicking through the menus, and for measuring frame rate.
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--play"), i + 1 < argv.count,
           let level = Int(argv[i + 1]) {
            setMenuVisible(false)
            game.startLevel(max(0, min(level - 1, LevelCatalog.count - 1)))
        } else {
            setMenuVisible(true)
            game.setMode(.mainMenu)
        }
    }

    static func setMenuVisible(_ visible: Bool) {
        guard let host = hostingView else { return }
        host.isHidden = !visible
        if visible {
            host.window?.makeFirstResponder(host)
        } else {
            // Give keyboard focus back to the game view, or pause and reload stop
            // responding after the first menu visit.
            if let gameView = host.superview {
                host.window?.makeFirstResponder(gameView)
            }
        }
    }
}
