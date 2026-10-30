#if DEBUG
import AppKit
import SafeCore

// WP4. Tests of what is checked in the dialogs, run by Safe --app-tests.

enum PromptTests {
    static let cases: [AppTests.Case] = [
        AppTests.Case("a new password must be typed the same twice and not be empty") {
            AppTests.check(PasswordPrompt.newPasswordProblem("", "") != nil, "empty accepted")
            AppTests.check(PasswordPrompt.newPasswordProblem("abc", "abd") != nil, "different accepted")
            AppTests.check(PasswordPrompt.newPasswordProblem("abc", "") != nil, "second empty accepted")
            AppTests.check(PasswordPrompt.newPasswordProblem("", "abc") != nil, "first empty accepted")
            AppTests.equal(PasswordPrompt.newPasswordProblem("abc", "abc"), nil)
            AppTests.equal(PasswordPrompt.newPasswordProblem("Grüße 🔑", "Grüße 🔑"), nil)
            AppTests.equal(PasswordPrompt.newPasswordProblem(" ", " "), nil)
        },

        AppTests.Case("a new password with a line break, a control character or over 511 bytes is refused") {
            // finding of review round 2: a pasted line break went into the key, and no
            // other tool could open the file
            for (password, word) in [("pass word\n", "line break"), ("pass\rword", "line break"),
                                     ("pass\r\n", "line break"), ("pass\tword", "control character"),
                                     ("pass\u{7F}", "control character")] {
                let problem = PasswordPrompt.newPasswordProblem(password, password)
                AppTests.check(problem?.contains(word) == true, "\(password.debugDescription): \(problem ?? "accepted")")
            }
            let longest = String(repeating: "a", count: 511)
            AppTests.equal(PasswordPrompt.newPasswordProblem(longest, longest), nil)
            let tooLong = longest + "ä"
            AppTests.check(PasswordPrompt.newPasswordProblem(tooLong, tooLong)?.contains("511") == true, "513 bytes accepted")
        },

        AppTests.Case("a typed password loses line breaks at its end, which pasting adds") {
            AppTests.equal(PasswordPrompt.typedPassword("secret\n"), "secret")
            AppTests.equal(PasswordPrompt.typedPassword("secret\r\n"), "secret")
            AppTests.equal(PasswordPrompt.typedPassword("secret\n\n"), "secret")
            AppTests.equal(PasswordPrompt.typedPassword("sec\nret"), "sec\nret")
            AppTests.equal(PasswordPrompt.typedPassword(" secret "), " secret ")
            AppTests.equal(PasswordPrompt.typedPassword("Grüße 🔑\n"), "Grüße 🔑")
        },

        AppTests.Case("a password of non-Latin letters or emoji is told to need pasting") {
            // finding of review round 4: secure fields take only Roman input sources and no
            // emoji palette, so such a password can only be pasted
            for password in ["Пароль-1", "κωδικός", "סיסמה", "كلمة", "密码123", "パスワード", "비밀번호",
                             "Grüße-Paßwort-日本-🔐", "lock🔑", "heart\u{2764}\u{FE0F}"] {
                AppTests.check(PasswordPrompt.needsPasting(password), password)
            }
            for password in ["simple", "Grüße-Paßwort", "Ça-va-àéèêë", "Łódź-Žluť-ĳ", "Tiếng Việt",
                             "€£¥§±≠∞ —…", "π-Ω-µ", "\u{F8FF} apple", "tab-less 123 !@#$%^&*()"] {
                AppTests.check(!PasswordPrompt.needsPasting(password), password)
            }
            AppTests.check(PasswordPrompt.pastingNote.contains("paste"), PasswordPrompt.pastingNote)
        },

        AppTests.Case("two ways of writing an accented letter are different passwords") {
            // the same ü, composed and decomposed: equal as Swift strings, not as bytes
            let composed = "gr\u{00FC}n", decomposed = "gru\u{0308}n"
            AppTests.check(composed == decomposed)
            AppTests.check(PasswordPrompt.newPasswordProblem(composed, decomposed) != nil,
                           "different bytes accepted as the same password")
        },

        AppTests.Case("the password form is laid out with room for its fields") {
            let first = NSSecureTextField(), second = NSSecureTextField()
            let form = PasswordPrompt.form([("Password:", first), ("Again:", second)])
            AppTests.check(form.frame.width >= 260 && form.frame.width < 400, "width \(form.frame.width)")
            AppTests.check(form.frame.height >= 44 && form.frame.height < 120, "height \(form.frame.height)")
        },

        AppTests.Case("the password dialogs have secure fields, OK and Cancel, and are not shared") {
            guard OffScreen.available else { return }
            let (once, field) = PasswordPrompt.onceAlert(title: "Open “safetest.txt.crypt”",
                                                         message: "Type the password of “safetest.txt.crypt”.")
            once.layout()
            AppTests.equal(once.buttons.map(\.title), ["OK", "Cancel"])
            AppTests.equal(once.buttons.last?.keyEquivalent, "\u{1b}")
            AppTests.equal(once.window.sharingType, .none)
            AppTests.check(once.window.initialFirstResponder === field)
            AppTests.check(!once.window.isVisible, "the dialog is on the screen")
            OffScreen.render(once.window, as: "password-once")

            let (twice, first, second) = PasswordPrompt.twiceAlert(title: "Encrypt “safetest.txt”",
                                                                   message: "Type a password twice.")
            twice.layout()
            AppTests.check(first.nextKeyView === second, "Tab does not lead from the first field to the second")
            AppTests.check(twice.window.initialFirstResponder === first,
                           "first responder \(String(describing: twice.window.initialFirstResponder))")
            AppTests.check(!twice.window.isVisible, "the dialog is on the screen")
            OffScreen.render(twice.window, as: "password-twice")

            let panel = ModalProgress.makePanel("Copying “safetest-folder” into a new encrypted volume ...")
            AppTests.check(!panel.isVisible, "the progress panel is on the screen")
            OffScreen.render(panel, as: "progress")
        },

        AppTests.Case("sizes are read in MB, GB or TB, GB if no unit") {
            AppTests.equal(VolumeInput.parseSizeMB("1 GB"), 1024)
            AppTests.equal(VolumeInput.parseSizeMB("1GB"), 1024)
            AppTests.equal(VolumeInput.parseSizeMB(" 500 mb "), 500)
            AppTests.equal(VolumeInput.parseSizeMB("2"), 2048)
            AppTests.equal(VolumeInput.parseSizeMB("0.5 GB"), 512)
            AppTests.equal(VolumeInput.parseSizeMB("0,5 G"), 512)
            AppTests.equal(VolumeInput.parseSizeMB("1 TB"), 1024 * 1024)
            AppTests.equal(VolumeInput.parseSizeMB("50m"), 50)
            AppTests.equal(VolumeInput.parseSizeMB("5 MB"), nil)
            AppTests.equal(VolumeInput.parseSizeMB(""), nil)
            AppTests.equal(VolumeInput.parseSizeMB("abc"), nil)
            AppTests.equal(VolumeInput.parseSizeMB("-1 GB"), nil)
            AppTests.equal(VolumeInput.parseSizeMB("1e3"), nil)
            AppTests.equal(VolumeInput.parseSizeMB("1 PB"), nil)
        },

        AppTests.Case("volume names are checked") {
            AppTests.equal(VolumeInput.nameProblem("safetest volume"), nil)
            AppTests.check(VolumeInput.nameProblem("") != nil)
            AppTests.check(VolumeInput.nameProblem("a/b") != nil)
            AppTests.check(VolumeInput.nameProblem("a:b") != nil)
            AppTests.check(VolumeInput.nameProblem(".hidden") != nil)
            AppTests.check(VolumeInput.nameProblem(String(repeating: "x", count: 61)) != nil)
            AppTests.equal(VolumeInput.volumeName(from: "safetest:folder"), "safetest-folder")
            AppTests.equal(VolumeInput.volumeName(from: ".safetest"), "safetest")
            AppTests.equal(VolumeInput.volumeName(from: "..."), "Private")
            AppTests.equal(VolumeInput.nameProblem(VolumeInput.volumeName(from: String(repeating: "é", count: 50))), nil)
        },

        AppTests.Case("paths under the home folder are stored with ~/") {
            let home = "/Users/safetest"
            AppTests.equal(VolumeInput.storedPath("/Users/safetest/Sync/a.sparsebundle", home: home), "~/Sync/a.sparsebundle")
            AppTests.equal(VolumeInput.storedPath("/Users/safetester/a.sparsebundle", home: home), "/Users/safetester/a.sparsebundle")
            AppTests.equal(VolumeInput.storedPath("/Volumes/Disk/a.dmg", home: home + "/"), "/Volumes/Disk/a.dmg")
            AppTests.equal(VolumeInput.expandedPath("~/Sync/a.sparsebundle", home: home), "/Users/safetest/Sync/a.sparsebundle")
            AppTests.equal(VolumeInput.expandedPath("/Volumes/Disk/a.dmg", home: home), "/Volumes/Disk/a.dmg")
            AppTests.equal(VolumeInput.expandedPath("~", home: home), home)
        },

        AppTests.Case("errors are named in words") {
            AppTests.check(Wording.describe(CryptError.wrongPassword).contains("password"))
            AppTests.check(Wording.describe(CryptError.alreadyExists("a.crypt")).contains("a.crypt"))
            AppTests.equal(Wording.describe(CryptError.io("disk full")), "disk full")
            for variant in CryptVariant.allCases {
                AppTests.check(!Wording.describe(variant).isEmpty)
            }
            AppTests.check(Wording.describe(CryptVariant.legacyRC4MD5).contains("RC4"))
        },
    ]
}
#endif
