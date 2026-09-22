import AppKit

@MainActor
enum SettingsStyle {
    static var background: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? .windowBackgroundColor
            : .windowBackgroundColor.withAlphaComponent(0.72)
    }
    static let text = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let border = NSColor.separatorColor

    static func symbol(_ name: String, color: NSColor = secondary) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    static func actionButton(_ title: String, symbol: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.font = .systemFont(ofSize: 13, weight: .medium)
        setSymbol(symbol, on: button)
        button.focusRingType = .default
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
        #else
        button.bezelStyle = .rounded
        #endif
        return button
    }

    static func setSymbol(_ name: String, on button: NSButton) {
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    static func prepareWindow(_ window: NSWindow) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = reduceTransparency
        window.backgroundColor = background
    }

    static func backdrop() -> NSVisualEffectView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let view = NSVisualEffectView()
        view.material = reduceTransparency ? .contentBackground : .underWindowBackground
        view.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        view.state = reduceTransparency ? .inactive : .active
        return view
    }

    static func glassContainer(for content: NSView, cornerRadius: CGFloat = 12) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        #endif

        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .withinWindow
        effect.state = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .inactive : .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = border.withAlphaComponent(0.55).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        return effect
    }
}

@MainActor
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w":
                performClose(nil)
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

// The mode cards draw beyond a radio cell's native glyph and title, so their
// whole visible surface needs to track the mouse.
@MainActor
private final class SettingsButtonCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

// The two mode choices keep their card layout while retaining NSButton's radio
// semantics. All ordinary actions and checkboxes are plain NSButton instances.
@MainActor
final class SettingsButton: NSButton {
    var symbolName: String { didSet { needsDisplay = true } }
    var displayTitle: String? { didSet { needsDisplay = true } }
    var detail: String? { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    init(_ title: String, symbol: String, target: AnyObject?, action: Selector?) {
        symbolName = symbol
        super.init(frame: .zero)
        cell = SettingsButtonCell(textCell: "")
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.radio)
        font = .systemFont(ofSize: 13, weight: .medium)
        isBordered = false
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font!]).width + 56
        return NSSize(width: width, height: 64)
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
        let foreground = NSColor.controlTextColor.withAlphaComponent(alpha)
        let secondary = (selected ? NSColor.controlTextColor : SettingsStyle.secondary).withAlphaComponent(alpha)
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        let fill = selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) :
            pressed ? NSColor.selectedControlColor.withAlphaComponent(0.18) :
            hovered ? NSColor.controlTextColor.withAlphaComponent(0.07) : NSColor.clear
        fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
        box.fill()
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.45) : SettingsStyle.border).setStroke()
        box.lineWidth = 1
        box.stroke()
        SettingsStyle.symbol(symbolName, color: secondary)?
            .draw(in: NSRect(x: 12, y: 13, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textRect = NSRect(x: 38, y: 12, width: max(0, bounds.width - 74), height: 19)
        ((displayTitle ?? title) as NSString).draw(in: textRect, withAttributes: [.font: font!, .foregroundColor: foreground, .paragraphStyle: paragraph])
        if let detail {
            (detail as NSString).draw(in: NSRect(x: 38, y: 35, width: bounds.width - 48, height: 18),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary, .paragraphStyle: paragraph])
        }
        if selected {
            SettingsStyle.symbol("checkmark", color: foreground)?.draw(in: NSRect(x: bounds.width - 24, y: 14, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
    }
}
