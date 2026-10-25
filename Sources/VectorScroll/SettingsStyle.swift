import AppKit

@MainActor
enum SettingsStyle {
    static let text = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    // Solid colors matching the 1.8 look: groups share the window color and
    // only a light edge separates them, so the glass parts read darker.
    static let background = NSColor(name: "SettingsBackground", dynamicProvider: { (appearance: NSAppearance) -> NSColor in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 40 / 255 : 236 / 255, alpha: 1)
    })
    static let groupFill = NSColor(name: "SettingsGroupFill", dynamicProvider: { (appearance: NSAppearance) -> NSColor in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.04) : NSColor.white.withAlphaComponent(0.7)
    })

    static func setSymbol(_ name: String, on button: NSButton) {
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    static func actionButton(_ title: String, symbol: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.font = .systemFont(ofSize: 13, weight: .medium)
        setSymbol(symbol, on: button)
        button.bezelStyle = .rounded
        #if compiler(>=6.2)
        if #available(macOS 26, *) { button.bezelStyle = .glass }
        #endif
        return button
    }

    static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = SettingsLabel(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: secondary ? 11 : 13)
        field.textColor = secondary ? Self.secondary : Self.text
        field.preferredMaxLayoutWidth = 400
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    static func column(_ views: [NSView], spacing: CGFloat = 2) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    static func row(_ title: String, control: NSView, description: NSTextField? = nil, icon: NSImageView? = nil) -> NSView {
        row(title: label(title), control: control, description: description, icon: icon)
    }

    static func row(title: NSTextField, control: NSView, description: NSTextField? = nil, icon: NSImageView? = nil) -> NSView {
        let text = column([title] + (description.map { [$0] } ?? []))
        // Keep the text at its natural height so centering puts it beside the control, not at the top of a stretched column.
        text.setHuggingPriority(.required, for: .vertical)
        if let stack = control as? NSStackView {
            stack.setHuggingPriority(.required, for: .horizontal)
            for view in stack.arrangedSubviews {
                view.setContentHuggingPriority(.required, for: .horizontal)
                view.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let content = NSView()
        for view in [text, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        var leading = content.leadingAnchor
        if let icon {
            icon.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leading),
                icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                content.heightAnchor.constraint(greaterThanOrEqualTo: icon.heightAnchor)
            ])
            leading = icon.trailingAnchor
        }
        let preferredHeight = content.heightAnchor.constraint(equalTo: text.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: icon == nil ? 0 : 8),
            text.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            control.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: text.heightAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor),
            preferredHeight
        ])
        return paddedRow(content)
    }

    static func paddedRow(_ content: NSView) -> NSView {
        let row = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9)
        ])
        return row
    }

    static func group(_ rows: [NSView]) -> NSView { SettingsGroup(rows: rows) }

    static func footnote(_ text: String) -> NSTextField { label(text, secondary: true) }

    // Menu bar apps can't count on activation. Bring the window to the current
    // Space, including over full-screen apps, and front it even if macOS declines.
    static func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func prepareWindow(_ window: NSWindow) {
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.titlebarAppearsTransparent = true
        // No visible title bar. The title stays for the Window menu and VoiceOver.
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = background
    }
}

// AppKit's wrapping labels need the actual column width after a resize, rather
// than the width of the whole pane, to calculate their intrinsic height.
@MainActor
private final class SettingsLabel: NSTextField {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, abs(preferredMaxLayoutWidth - newSize.width) > 0.5 {
            preferredMaxLayoutWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }
}

@MainActor
private final class SettingsGroup: NSBox {
    private let rows: [NSView]
    private var separators: [NSBox] = []

    init(rows: [NSView]) {
        self.rows = rows
        super.init(frame: .zero)
        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separators.append(separator)
                views.append(separator)
            }
            views.append(row)
        }
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 10
        fillColor = SettingsStyle.groupFill
        borderWidth = 0
        contentViewMargins = NSSize(width: 14, height: 0)
        let stack = SettingsStyle.column(views, spacing: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func layout() {
        var hasVisibleRow = false
        for (index, row) in rows.enumerated() {
            if index > 0 { separators[index - 1].isHidden = row.isHidden || !hasVisibleRow }
            if !row.isHidden { hasVisibleRow = true }
        }
        super.layout()
    }
}

// Keep actions at their native widths. Long translations and an available
// update can flow onto a second line instead of widening the settings window.
@MainActor
final class SettingsActionBar: NSView {
    private let leading: NSView?
    private let actions: [NSView]
    private let maximumWidth: CGFloat?

    init(leading: NSView? = nil, actions: [NSView], maximumWidth: CGFloat? = nil) {
        self.leading = leading
        self.actions = actions
        self.maximumWidth = maximumWidth
        super.init(frame: .zero)
        for view in (leading.map { [$0] } ?? []) + actions { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }

    func refresh() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(bounds.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { refresh() }
    }

    override var intrinsicContentSize: NSSize {
        let visible = measuredActions()
        let sizes = visible.map { $0.1 }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 8
        let width = maximumWidth.map { max(sizes.map(\.width).max() ?? 0, min($0, naturalWidth)) }
        let layoutWidth = bounds.width > 0 ? bounds.width : width ?? 552
        return NSSize(width: width ?? NSView.noIntrinsicMetric, height: placements(width: layoutWidth, visible: visible, leadingSize: measuredLeadingSize()).height)
    }

    private func measuredActions() -> [(NSView, NSSize)] {
        actions.filter { !$0.isHidden }.map { ($0, $0.fittingSize) }
    }

    private func measuredLeadingSize() -> NSSize {
        guard let leading, !leading.isHidden else { return .zero }
        return leading.fittingSize
    }

    private func placements(width: CGFloat, visible: [(NSView, NSSize)],
                            leadingSize: NSSize) -> (frames: [(NSView, NSRect)], height: CGFloat) {
        let actionWidth = visible.reduce(CGFloat.zero) { $0 + $1.1.width } + CGFloat(max(0, visible.count - 1)) * 8
        var frames: [(NSView, NSRect)] = []
        var y: CGFloat = 0
        if let leading, !leading.isHidden {
            if leadingSize.width + 16 + actionWidth <= width {
                let height = max(leadingSize.height, visible.map { $0.1.height }.max() ?? 0)
                frames.append((leading, NSRect(x: 0, y: (height - leadingSize.height) / 2, width: leadingSize.width, height: leadingSize.height)))
                var x = width - actionWidth
                for (view, size) in visible {
                    frames.append((view, NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)))
                    x += size.width + 8
                }
                return (frames, height)
            }
            frames.append((leading, NSRect(origin: .zero, size: leadingSize)))
            y = leadingSize.height + 8
        }
        var line: [(NSView, NSSize)] = []
        var lineWidth: CGFloat = 0
        func finishLine() {
            guard !line.isEmpty else { return }
            let height = line.map { $0.1.height }.max() ?? 0
            var x = width - lineWidth
            for (view, size) in line {
                frames.append((view, NSRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height)))
                x += size.width + 8
            }
            y += height + 8
            line = []
            lineWidth = 0
        }
        for (view, size) in visible {
            if !line.isEmpty, lineWidth + 8 + size.width > width { finishLine() }
            if !line.isEmpty { lineWidth += 8 }
            line.append((view, size))
            lineWidth += size.width
        }
        finishLine()
        return (frames, max(0, y - 8))
    }

    override func layout() {
        super.layout()
        for (view, frame) in placements(width: bounds.width, visible: measuredActions(), leadingSize: measuredLeadingSize()).frames { view.frame = frame }
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

// A native radio glyph centered on a title and description. AppKit keeps a
// radio's glyph on the first line of a multi-line title, so the text lives
// beside it, and a click anywhere on the row selects it.
@MainActor
final class SettingsChoiceRow: NSView {
    let button: NSButton
    let titleLabel: NSTextField
    let detailLabel: NSTextField

    init(button: NSButton, title: String, detail: NSTextField) {
        self.button = button
        titleLabel = SettingsStyle.label(title)
        detailLabel = detail
        super.init(frame: .zero)
        button.title = ""
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setAccessibilityLabel(button.accessibilityLabel() ?? title)
        let text = SettingsStyle.column([titleLabel, detailLabel])
        for view in [button, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === button ? button : self
    }

    override func mouseDown(with event: NSEvent) {
        if button.isEnabled { button.performClick(nil) }
    }
}
