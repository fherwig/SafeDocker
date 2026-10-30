import AppKit
import SafeCore

// WP4. The start sequence of section 4.1.

// 1. No network, before anything else. If that fails, say so and quit.
do {
    try NoNetwork.enforce()
} catch {
    // the message itself, not the debug form of the error, so that an agent can match it
    var message = "\(error)"
    if case .io(let text)? = error as? CryptError {
        message = text
    }
    if CommandLineMode.isRequested(CommandLine.arguments) {
        CommandLineMode.printError(message)
    } else {
        _ = NSApplication.shared
        Localization.resourceDirectory = AppInfo.resourcesDirectory
        Settings.shared.apply()
        let alert = NSAlert()
        alert.messageText = L("Safe cannot start")
        alert.informativeText = L("It could not switch off its own network access: %@", message)
        alert.runModal()
    }
    exit(1)
}

// 2. The modes without a window, for the install agent.
if let status = CommandLineMode.run(CommandLine.arguments) {
    exit(status)
}

// 3. and 4. The app, in the language of Safe's settings (the command-line modes
// above always speak English); AppDelegate starts the self-test and shows the first window.
Localization.resourceDirectory = AppInfo.resourcesDirectory
Settings.shared.apply()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
