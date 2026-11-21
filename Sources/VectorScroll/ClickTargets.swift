@preconcurrency import ApplicationServices
import Foundation

/// Finds links and browser tabs under the pointer, where a middle-click already means something.
enum ClickTargets {
    /// Each accessibility request may wait this long for the app under the pointer.
    private static let timeout: Float = 0.1

    static func contains(_ point: CGPoint) -> Bool {
        guard let hit = element(at: point) else { return false }
        var pid = pid_t()
        if AXUIElementGetPid(hit, &pid) == .success { prepare(pid) }
        if isLinkOrTab(hit) || isChromiumTab(hit, at: point) { return true }
        guard value("ChromeAXNodeId", of: hit) != nil else { return false }
        // Chromium answers a page hit from its cache and looks the point up in the background,
        // so the first element can belong to the previous click. A different one is the fresh answer.
        // ponytail: waits up to 50 ms on the main thread. Move the lookup off the event tap if busy pages need longer.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        while ProcessInfo.processInfo.systemUptime < deadline {
            usleep(3_000)
            guard let fresh = element(at: point) else { return false }
            if !CFEqual(fresh, hit) { return isLinkOrTab(fresh) }
        }
        return false
    }

    /// Chromium describes its pages only after something asks its application element for a role.
    /// False when the app didn't answer, which is normal while it is still launching.
    @discardableResult
    static func prepare(_ pid: pid_t) -> Bool {
        role(of: AXUIElementCreateApplication(pid)) != nil
    }

    private static func isLinkOrTab(_ hit: AXUIElement) -> Bool {
        var current: AXUIElement? = hit
        // Link text can sit several levels inside its link. Stop at the page or window.
        for _ in 0..<12 {
            guard let element = current, let role = role(of: element) else { return false }
            if role == "AXLink" { return true }
            if role == "AXRadioButton", value("AXSubrole", of: element) as? String == "AXTabButton" { return true }
            if role == "AXWebArea" || role == "AXWindow" { return false }
            current = parent(of: element)
        }
        return false
    }

    /// Chromium answers a hit on its tab strip with an empty group lying over the tabs,
    /// so find the tab group beside it and compare the tabs' frames.
    private static func isChromiumTab(_ hit: AXUIElement, at point: CGPoint) -> Bool {
        guard role(of: hit) == "AXGroup", let strip = parent(of: hit) else { return false }
        return children(of: strip).contains { group in
            role(of: group) == "AXTabGroup" && children(of: group).contains { frame(of: $0)?.contains(point) == true }
        }
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var element: AXUIElement?
        return AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success ? element : nil
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func role(of element: AXUIElement) -> String? {
        value("AXRole", of: element) as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = value("AXParent", of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value("AXChildren", of: element) as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let value = value("AXFrame", of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var frame = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &frame) ? frame : nil
    }
}
