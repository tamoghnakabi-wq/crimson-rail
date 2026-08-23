import Foundation
import AppKit

// Entry point. Harness flags run headless and exit; anything else launches the game.
let argv = CommandLine.arguments
let args = Harness.Args(argv)

if args.has("--isolated") {
    // Keep harness runs away from a real player's settings and progress files.
    Store.isolated = true
}

if args.has("--help") || args.has("-h") {
    Harness.out("""
    Crimson Rail

      (no arguments)          launch the game
      --shot <file.png>       render a level offscreen to a PNG
        --level N               1-5, default 1
        --at <metres>           distance along the rail, default 12
        --width / --height      pixels, default 1440x900
        --quality <preset>      low | medium | high | ultra
        --scenario <name>       play | wide | top
      --selftest              run invariant checks and exit
      --balance [--runs N]     simulate players and report survival statistics
      --audiotest [--dir D]    render every sound offline and report levels
      --perf [--seconds N]     frame-time percentiles
      --soak [--minutes N]     long chaotic run; invariants and leak checks
      --solo <file.png>       render the enemy cast in a studio scene
      --icon <file.icns>      generate the app icon
      --play N                launch straight into level N
      --isolated              never read or write the real settings/progress files
    """)
    exit(0)
}

if args.has("--icon") {
    exit(Harness.icon(args))
}
if args.has("--solo") {
    exit(Harness.solo(args))
}
if args.has("--shot") {
    exit(Harness.shot(args))
}
if args.has("--soak") {
    exit(Harness.soak(args))
}
if args.has("--selftest") {
    exit(Harness.selftest(args))
}
if args.has("--balance") {
    exit(Harness.balance(args))
}
if args.has("--audiotest") {
    exit(Harness.audiotest(args))
}
if args.has("--perf") {
    exit(Harness.perf(args))
}

// --- Normal launch -----------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
