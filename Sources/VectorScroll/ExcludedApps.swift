@preconcurrency import AppKit
import UniformTypeIdentifiers

@MainActor
enum ExcludedApps {
    @MainActor
    private final class ExclusionCache {
        let defaults: UserDefaults
        var ids: Set<String>?
        var observer: NSObjectProtocol?

        init(defaults: UserDefaults) {
            self.defaults = defaults
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ids = nil }
            }
        }
    }

    private static var caches: [ObjectIdentifier: ExclusionCache] = [:]
    private static var bundleIDsByPID: [pid_t: String] = [:]
    private static var workspaceObservers: [NSObjectProtocol] = []

    static func prepare() {
        _ = cachedBundleIDs(in: .standard)
        guard workspaceObservers.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            bundleIDsByPID[app.processIdentifier] = app.bundleIdentifier
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let id = app.bundleIdentifier
                MainActor.assumeIsolated {
                    bundleIDsByPID[pid] = name == NSWorkspace.didTerminateApplicationNotification ? nil : id
                }
            })
        }
    }

    static func cachedBundleIDs(in defaults: UserDefaults) -> Set<String> {
        let key = ObjectIdentifier(defaults)
        let cache = caches[key] ?? ExclusionCache(defaults: defaults)
        caches[key] = cache
        if let ids = cache.ids { return ids }
        let ids = Set(bundleIDs(in: defaults))
        cache.ids = ids
        return ids
    }

    static func bundleIDs(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "excludedBundleIDs") ?? []
    }

    static func add(_ bundleIDs: [String], to defaults: UserDefaults = .standard) {
        var stored = Self.bundleIDs(in: defaults)
        for id in bundleIDs where !id.isEmpty && !stored.contains(id) { stored.append(id) }
        defaults.set(stored, forKey: "excludedBundleIDs")
        caches[ObjectIdentifier(defaults)]?.ids = nil
    }

    static func remove(_ bundleID: String, from defaults: UserDefaults = .standard) {
        defaults.set(bundleIDs(in: defaults).filter { $0 != bundleID }, forKey: "excludedBundleIDs")
        caches[ObjectIdentifier(defaults)]?.ids = nil
    }

    static func isExcluded(at point: CGPoint) -> Bool {
        isExcluded(at: point, defaults: .standard)
    }

    static func isExcluded(at point: CGPoint, defaults: UserDefaults) -> Bool {
        let excluded = cachedBundleIDs(in: defaults)
        guard !excluded.isEmpty else { return false }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        guard let pid = ownerPID(at: point, in: windows) else { return false }
        let id = bundleIDsByPID[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard let id else { return false }
        bundleIDsByPID[pid] = id
        return excluded.contains(id)
    }

    static func ownerPID(at point: CGPoint, in windows: [[String: Any]]) -> pid_t? {
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  // Only normal app windows. Invisible overlays and the menu bar must not hide the app below.
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point) else { continue }
            return pid
        }
        return nil
    }

    static func makeSettingsSection(defaults: UserDefaults = .standard) -> NSView {
        ExcludedAppsRows(defaults: defaults)
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
        spacing = 6
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func rebuild() {
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        let ids = ExcludedApps.bundleIDs(in: defaults)
        var rows: [NSView] = []
        if ids.isEmpty {
            let empty = SettingsStyle.label(L("No excluded apps"))
            empty.textColor = SettingsStyle.secondary
            rows.append(SettingsStyle.paddedRow(empty))
        }
        for id in ids {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
            let icon = NSImageView(image: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!)
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
            icon.imageScaling = .scaleProportionallyUpOrDown
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: L("Remove %@", name))!, target: self, action: #selector(removeApp(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(id)
            remove.isBordered = false
            remove.contentTintColor = SettingsStyle.secondary
            rows.append(SettingsStyle.row(name, control: remove, icon: icon))
        }
        let group = SettingsStyle.group(rows)
        addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let add = SettingsStyle.actionButton(L("Add App…"), symbol: "plus", target: self, action: #selector(addApps))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spacer, add])
        addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let footnote = SettingsStyle.footnote(L("Middle-button scrolling is off in these apps. Useful for apps that pan with the middle button, like Blender or Figma."))
        addArrangedSubview(footnote)
        footnote.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
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
