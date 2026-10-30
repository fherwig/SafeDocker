import AppKit
import SafeCore

// Version 0.3.0: Safe's settings, for now only the language of its windows and
// messages (architecture.md, section 12). The choice is kept in the app's own
// defaults; the app tests use a suite of their own instead.

/// Safe's settings.
final class Settings {
    /// The settings of the app, in its own defaults domain.
    static let shared = Settings(defaults: .standard, setsAppKitLanguage: true)

    /// Posted on the main thread after Safe's language changed; the menu bar,
    /// the Volumes window, the help and the Settings window take their texts again.
    static let languageDidChange = Notification.Name("SafeLanguageDidChange")

    /// The key of the choice in the defaults.
    static let languageKey = "SafeLanguage"

    /// What the user chose: macOS's languages, or one language.
    enum LanguageChoice: String, CaseIterable {
        case system, english = "en", german = "de"
    }

    let defaults: UserDefaults
    /// Whether a choice also sets AppleLanguages in the defaults, the language
    /// of what AppKit draws for Safe (the Open and Save dialogs, the About
    /// window) from the next start on. Only the app's own settings do.
    let setsAppKitLanguage: Bool
    /// macOS's preferred languages, first the most preferred: the list in System
    /// Settings, or the one System Settings keeps for Safe alone. The checks replace it.
    var systemLanguages: () -> [String]

    init(defaults: UserDefaults, setsAppKitLanguage: Bool = false) {
        self.defaults = defaults
        self.setsAppKitLanguage = setsAppKitLanguage
        systemLanguages = {
            defaults.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        }
    }

    /// The choice kept in the defaults; System if there is none.
    var languageChoice: LanguageChoice {
        defaults.string(forKey: Self.languageKey).flatMap(LanguageChoice.init(rawValue:)) ?? .system
    }

    /// The language the choice gives now.
    var language: AppLanguage {
        Self.resolve(languageChoice, preferred: systemLanguages())
    }

    /// System means German if German comes before English in macOS's list,
    /// and English otherwise, also when neither is in it.
    static func resolve(_ choice: LanguageChoice, preferred: [String]) -> AppLanguage {
        switch choice {
        case .english:
            return .english
        case .german:
            return .german
        case .system:
            for code in preferred {
                let lower = code.lowercased()
                if lower == "de" || lower.hasPrefix("de-") || lower.hasPrefix("de_") {
                    return .german
                }
                if lower == "en" || lower.hasPrefix("en-") || lower.hasPrefix("en_") {
                    return .english
                }
            }
            return .english
        }
    }

    /// Makes Safe use the language of the choice kept; at start.
    func apply() {
        Localization.language = language
    }

    /// Keeps a new choice and switches Safe's texts to it at once. Windows with
    /// decrypted content are not touched: they keep their texts until they are
    /// opened again.
    func setLanguageChoice(_ choice: LanguageChoice) {
        if choice == .system {
            defaults.removeObject(forKey: Self.languageKey)
        } else {
            defaults.set(choice.rawValue, forKey: Self.languageKey)
        }
        if setsAppKitLanguage {
            // remove ours before asking macOS's list, so that System reads macOS's own
            if choice == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([choice.rawValue], forKey: "AppleLanguages")
            }
        }
        let before = Localization.language
        apply()
        if Localization.language != before {
            NotificationCenter.default.post(name: Self.languageDidChange, object: self)
        }
    }

    // MARK: what needs a new start

    /// The language AppKit uses for its own texts in this run (en or de),
    /// fixed when Safe started.
    static let appKitLanguageAtStart: String = {
        let first = Bundle.main.preferredLocalizations.first ?? "en"
        return first.hasPrefix("de") ? "de" : "en"
    }()

    /// True if what AppKit draws for Safe is in another language than Safe's
    /// own texts until Safe starts again. Only inside Safe.app, whose
    /// localizations AppKit knows.
    var needsRestart: Bool {
        runsInsideApp && appKitLanguage != Localization.language.rawValue
    }

    /// The language of AppKit's texts in this run; the checks set another.
    var appKitLanguage = Settings.appKitLanguageAtStart
    /// True inside Safe.app; the checks set it.
    var runsInsideApp = Bundle.main.bundleURL.pathExtension == "app"

    /// True if Safe may start again now: nothing decrypted is shown (no editor
    /// or viewer, so no unsaved text) and no volume that Safe opened is open.
    /// The checks replace it.
    var nothingIsOpen: () -> Bool = {
        !DocumentRouter.shared.hasOpenWindows && EditorWindowController.openEditors.isEmpty
            && !VolumeController.shared.hasAppOpenedVolumes
    }

    /// Starts a new Safe and quits this one; only when nothingIsOpen. The checks replace it.
    var restart: () -> Void = {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    Alerts.inform(L("Safe could not start again"), error.localizedDescription)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
