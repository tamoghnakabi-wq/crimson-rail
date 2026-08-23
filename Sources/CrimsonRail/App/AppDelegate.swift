import Foundation
import AppKit
import SceneKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var gameView: GameView!
    private var game: Game!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Store.loadSettings()

        let contentRect = NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Crimson Rail"
        window.minSize = NSSize(width: 960, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        // A dark window chrome so the frame does not glow around a night scene.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black

        gameView = GameView(frame: contentRect)
        gameView.autoresizingMask = [.width, .height]
        gameView.backgroundColor = .black
        gameView.allowsCameraControl = false
        gameView.showsStatistics = false
        window.contentView = gameView

        game = Game(view: gameView)
        UIRoot.install(in: gameView, game: game)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(gameView)
        NSApp.activate(ignoringOtherApps: true)

        if settings.gameplay.fullscreenOnLaunch {
            window.toggleFullScreen(nil)
        }

        buildMenuBar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Hand the pointer back before going away, so a quit mid-mission cannot
        // strand the system mouse in its decoupled state.
        game.releaseInputCapture()
        game.flushSettings()
        game.save.persist()
    }

    /// A minimal menu bar. Without one, Cmd-Q does not work and the app looks
    /// broken on macOS even though it runs fine.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Crimson Rail", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Crimson Rail", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Crimson Rail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
