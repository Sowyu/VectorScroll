import AppKit

@MainActor
enum SettingsStyle {
    static let background = NSColor(calibratedWhite: 0.115, alpha: 1)
    static let text = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.65, alpha: 1)
    static let border = NSColor(calibratedWhite: 0.23, alpha: 1)
    static let coral = NSColor(calibratedRed: 1, green: 0.36, blue: 0.39, alpha: 1)

    static func symbol(_ name: String, color: NSColor = secondary) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }
}

@MainActor
final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

// Native switch/radio cells only hit-test their original glyph and title.
// Our drawing fills the control, so its entire bounds must track the mouse.
@MainActor
private final class SettingsButtonCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

// Keep NSButton's tracking, keyboard activation, and accessibility semantics.
// Only the drawing changes; settings still use the same targets and state.
@MainActor
final class SettingsButton: NSButton {
    enum Kind { case action, toggle, choice, destructive }
    let kind: Kind
    let symbolName: String
    var displayTitle: String?
    var detail: String? { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    init(_ title: String, symbol: String, kind: Kind = .action, target: AnyObject?, action: Selector?) {
        self.kind = kind
        symbolName = symbol
        super.init(frame: .zero)
        cell = SettingsButtonCell(textCell: "")
        self.title = title
        self.target = target
        self.action = action
        setButtonType(kind == .toggle ? .switch : kind == .choice ? .radio : .momentaryPushIn)
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .medium)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font!]).width + 56
        return NSSize(width: width, height: kind == .choice ? 64 : 34)
    }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let pressed = cell?.isHighlighted == true
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        let foreground = (kind == .destructive ? NSColor(calibratedWhite: 0.1, alpha: 1) : SettingsStyle.text).withAlphaComponent(alpha)
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        if kind != .toggle || hovered || pressed {
            let fill: NSColor = kind == .destructive ? SettingsStyle.coral :
                NSColor(calibratedWhite: pressed ? 0.28 : hovered ? 0.25 : selected ? 0.21 : kind == .choice ? 0.14 : 0.21, alpha: 1)
            fill.withAlphaComponent(alpha).setFill()
            box.fill()
            if kind == .choice || selected {
                NSColor(calibratedWhite: selected ? 0.48 : 0.24, alpha: alpha).setStroke()
                box.stroke()
            }
        }
        if window?.firstResponder === self {
            foreground.setStroke()
            box.lineWidth = 2
            box.stroke()
        }
        let iconY: CGFloat = kind == .choice ? 13 : (bounds.height - 16) / 2
        SettingsStyle.symbol(symbolName, color: kind == .destructive ? foreground : SettingsStyle.secondary.withAlphaComponent(alpha))?
            .draw(in: NSRect(x: 12, y: iconY, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let rightInset: CGFloat = kind == .toggle ? 54 : kind == .choice ? 30 : 12
        let textRect = NSRect(x: 38, y: kind == .choice ? 12 : (bounds.height - 17) / 2,
                              width: max(0, bounds.width - 38 - rightInset), height: 19)
        ((displayTitle ?? title) as NSString).draw(in: textRect, withAttributes: [.font: font!, .foregroundColor: foreground, .paragraphStyle: paragraph])
        if let detail, kind == .choice {
            (detail as NSString).draw(in: NSRect(x: 38, y: 35, width: bounds.width - 48, height: 18),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: SettingsStyle.secondary, .paragraphStyle: paragraph])
        }
        if kind == .choice && selected {
            SettingsStyle.symbol("checkmark", color: foreground)?.draw(in: NSRect(x: bounds.width - 25, y: 14, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if kind == .toggle {
            let track = NSRect(x: bounds.width - 43, y: (bounds.height - 20) / 2, width: 32, height: 20)
            NSColor(calibratedWhite: selected ? 0.9 : 0.32, alpha: alpha).setFill()
            NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()
            NSColor(calibratedWhite: selected ? 0.16 : 0.8, alpha: alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: track.minX + (selected ? 14 : 3), y: track.minY + 3, width: 14, height: 14)).fill()
        }
    }
}
