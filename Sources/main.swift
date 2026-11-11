// One binary, two faces: the menu bar app (launched from Finder) and the `awake` CLI (run in a terminal).
import Cocoa

let args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, CLI.commands.contains(first) {
    exit(CLI.main(args))
} else if args.isEmpty && isatty(0) != 0 && isatty(1) != 0 {
    exit(CLI.main([]))   // plain `awake` in a terminal shows the status
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
