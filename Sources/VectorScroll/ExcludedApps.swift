@preconcurrency import AppKit
import UniformTypeIdentifiers

@MainActor
enum ExcludedApps {
    static func bundleIDs(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "excludedBundleIDs") ?? []
    }

    static func add(_ bundleIDs: [String], to defaults: UserDefaults = .standard) {
        var stored = Self.bundleIDs(in: defaults)
        for id in bundleIDs where !id.isEmpty && !stored.contains(id) { stored.append(id) }
        defaults.set(stored, forKey: "excludedBundleIDs")
    }

    static func remove(_ bundleID: String, from defaults: UserDefaults = .standard) {
        defaults.set(bundleIDs(in: defaults).filter { $0 != bundleID }, forKey: "excludedBundleIDs")
    }

    static func isExcluded(at point: CGPoint) -> Bool {
        isExcluded(at: point, defaults: .standard)
    }

    static func isExcluded(at point: CGPoint, defaults: UserDefaults) -> Bool {
        let excluded = bundleIDs(in: defaults)
        guard !excluded.isEmpty else { return false }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  // Only normal app windows. Invisible overlays and the menu bar must not hide the app below.
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point) else { continue }
            guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
            return excluded.contains(id)
        }
        return false
    }

    static func makeSettingsSection(defaults: UserDefaults = .standard) -> NSView {
        let rows = ExcludedAppsRows(defaults: defaults)
        return MouseSettingsStyle.group([
            rows,
            MouseSettingsStyle.note(L("Middle-button scrolling and side buttons are off in these apps. Useful for apps that pan with the middle button, like Blender or Figma."))
        ])
    }
}

@MainActor
private final class ExcludedAppsRows: NSStackView {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func rebuild() {
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        let ids = ExcludedApps.bundleIDs(in: defaults)
        if ids.isEmpty { addArrangedSubview(MouseSettingsStyle.note(L("No excluded apps"))) }
        for id in ids {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
            let icon = NSImageView(image: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!)
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            icon.imageScaling = .scaleProportionallyUpOrDown
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L("Remove %@", name))!, target: self, action: #selector(removeApp(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(id)
            remove.isBordered = false
            let row = NSStackView(views: [icon, MouseSettingsStyle.row(name, control: remove)])
            row.spacing = 8
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        addArrangedSubview(SettingsStyle.actionButton(L("Add App…"), symbol: "plus", target: self, action: #selector(addApps)))
    }

    @objc private func removeApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        ExcludedApps.remove(id, from: defaults)
        rebuild()
    }

    @objc private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L("Add")
        guard panel.runModal() == .OK else { return }
        ExcludedApps.add(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }, to: defaults)
        rebuild()
    }
}
