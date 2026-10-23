import AppKit

func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: L(format), locale: Locale.current, arguments: arguments)
}

@MainActor
final class LanguagePicker: NSPopUpButton {
    init() {
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        controlSize = .small
        imagePosition = .imageOnly
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        toolTip = L("Language")
        setAccessibilityLabel(L("Language"))
        let menu = NSMenu()
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        heading.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Language"))
        menu.addItem(heading)
        let choice = Self.currentChoice
        func addChoice(_ title: String, code: String?) {
            let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = choice == code ? .on : .off
            menu.addItem(item)
        }
        addChoice(L("System Language"), code: nil)
        let languages = Bundle.main.localizations.filter { $0 != "Base" }.map { code in
            let locale = Locale(identifier: code)
            let name = (locale.localizedString(forIdentifier: code) ?? code).capitalized(with: locale)
            return (code: code, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for language in languages { addChoice(language.name, code: language.code) }
        self.menu = menu
        widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private static var currentChoice: String? {
        // Ignore the global AppleLanguages domain: an absent app override means System Language.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return (UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String])?.first
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let code = sender.representedObject as? String
        guard code != Self.currentChoice else { return }
        // Start the waiter before changing preferences or quitting, so a launch failure is recoverable.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; /usr/bin/open "$2" --args --show-settings"#,
                             "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
            if let code { defaults.set([code], forKey: "AppleLanguages") }
            else { defaults.removeObject(forKey: "AppleLanguages") }
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Language could not be changed")
            alert.informativeText = L(error.localizedDescription)
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }
}

// Keep fixed updater errors discoverable while those files also compile standalone.
func localizedUpdateError(_ message: String) -> String {
    switch message {
    case "GitHub reported an invalid update size.": L("GitHub reported an invalid update size.")
    case "Invalid update health check destination.": L("Invalid update health check destination.")
    case "Invalid update health check.": L("Invalid update health check.")
    case "Invalid update plan.": L("Invalid update plan.")
    case "The app version could not be compared with the latest release.": L("The app version could not be compared with the latest release.")
    case "The downloaded app has an invalid executable.": L("The downloaded app has an invalid executable.")
    case "The downloaded app has the wrong version.": L("The downloaded app has the wrong version.")
    case "The installed app changed while updating. Please check for updates again.": L("The installed app changed while updating. Please check for updates again.")
    case "The installed app is not signed by the VectorScroll release identity. Reinstall it manually before updating.": L("The installed app is not signed by the VectorScroll release identity. Reinstall it manually before updating.")
    case "The installed app's code signature is invalid. Reinstall VectorScroll manually before updating.": L("The installed app's code signature is invalid. Reinstall VectorScroll manually before updating.")
    case "The installed app's signing identity could not be read.": L("The installed app's signing identity could not be read.")
    case "The latest release has no supported installer. Try again later.": L("The latest release has no supported installer. Try again later.")
    case "The update could not atomically replace the installed app. Your previous app has been kept.": L("The update could not atomically replace the installed app. Your previous app has been kept.")
    case "The update did not match GitHub's SHA-256 checksum. Nothing was installed.": L("The update did not match GitHub's SHA-256 checksum. Nothing was installed.")
    case "The update does not contain a valid VectorScroll app.": L("The update does not contain a valid VectorScroll app.")
    case "The update download was incomplete. Please try again.": L("The update download was incomplete. Please try again.")
    case "The update download was larger than GitHub reported. Nothing was installed.": L("The update download was larger than GitHub reported. Nothing was installed.")
    case "The update has an invalid Info.plist.": L("The update has an invalid Info.plist.")
    case "The update has an invalid minimum macOS version.": L("The update has an invalid minimum macOS version.")
    case "The update has an unreadable code signature.": L("The update has an unreadable code signature.")
    case "The update helper could not start. The current app is still installed.": L("The update helper could not start. The current app is still installed.")
    case "The update was not signed by the same identity as the installed app.": L("The update was not signed by the same identity as the installed app.")
    case "The updated app did not finish starting. The previous version was restored.": L("The updated app did not finish starting. The previous version was restored.")
    case "This copy cannot update in its current location. Move VectorScroll from the DMG into a writable Applications folder, then try again.": L("This copy cannot update in its current location. Move VectorScroll from the DMG into a writable Applications folder, then try again.")
    case "This update does not support this Mac's processor.": L("This update does not support this Mac's processor.")
    case "This update is not newer than the installed app.": L("This update is not newer than the installed app.")
    case "This update requires a newer version of macOS.": L("This update requires a newer version of macOS.")
    case "VectorScroll did not quit in time. Please try again.": L("VectorScroll did not quit in time. Please try again.")
    default: L(message)
    }
}
