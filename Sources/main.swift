import AppKit

if let code = CLI.run(CommandLine.arguments) {
    exit(code)
}

let application = NSApplication.shared
let delegate = AppDelegate(flags: Flags.parse(CommandLine.arguments))
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
