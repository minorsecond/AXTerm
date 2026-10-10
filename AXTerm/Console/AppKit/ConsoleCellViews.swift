#if os(macOS)
import AppKit
import SwiftUI

/// What a row does when it is clicked.
struct ConsoleTableActions {
    var onIdentity: ((String) -> Void)?
    var onIdentityMenu: ((String) -> Void)?
    var onFileName: ((String) -> Void)?
    var toggleExpanded: (UUID) -> Void = { _ in }
}

/// Symbols drawn into rows, made once per name, size and color.
@MainActor
enum ConsoleSymbolCache {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.description)"
        if let image = images[key] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        images[key] = image
        return image
    }
}

/// The message: real selectable text, with links that stay in the app.
final class ConsoleMessageTextView: NSTextView {
    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFindBar = false
        linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
    }

    /// A selection belongs to the row being read; moving on clears it, so the
    /// console does not collect gray highlights in rows read earlier.
    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: 0, length: 0))
        return super.resignFirstResponder()
    }

    /// Let the row handle a click it owns: the text view covers only the
    /// message, and everything else is the row's.
    override var acceptsFirstResponder: Bool { true }
}

/// One console line, drawn directly rather than built from views.
///
/// Rows are reused as the table scrolls; configuring one swaps its model and
/// redraws. The time, callsigns and chips are drawn; the message is a text
/// view so it can be selected and its links clicked.
final class ConsoleLineCellView: NSTableCellView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("ConsoleLineCell")
    /// Room each side, as the SwiftUI console's content padding gave.
    static let horizontalInset: CGFloat = 16

    private(set) var lineID: UUID?
    private var model: ConsoleRowModel?
    private var measurements: ConsoleRowMeasurements?
    private var geometry: ConsoleRowGeometry?
    private var actions = ConsoleTableActions()
    let messageView = ConsoleMessageTextView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        messageView.delegate = self
        addSubview(messageView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func configure(lineID: UUID, model: ConsoleRowModel, measurements: ConsoleRowMeasurements,
                   geometry: ConsoleRowGeometry, actions: ConsoleTableActions) {
        self.lineID = lineID
        self.model = model
        self.measurements = measurements
        self.geometry = geometry
        self.actions = actions
        messageView.textStorage?.setAttributedString(model.message)
        messageView.toolTip = model.messageHelp
        messageView.alphaValue = model.alpha
        setAccessibilityLabel(model.accessibilityLabel)
        setAccessibilityCustomActions(model.header.compactMap { item in
            guard let call = item.callsign, let onIdentity = actions.onIdentity else { return nil }
            return NSAccessibilityCustomAction(name: "Show \(call)") { onIdentity(call); return true }
        })
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        rebuildToolTips()
    }

    /// Recompute where things go for a new width.
    func update(geometry: ConsoleRowGeometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        rebuildToolTips()
    }

    private var origin: CGPoint { CGPoint(x: Self.horizontalInset, y: 0) }

    override func layout() {
        super.layout()
        guard let geometry else { return }
        messageView.frame = geometry.messageRect.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let geometry, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(model.alpha)
        defer { context.restoreGState() }

        let o = origin
        let backgroundHeight = (model.expansion.isEmpty ? geometry.height : geometry.expansionTop + ConsoleRowGeometry.padding)
        let rowRect = CGRect(x: o.x, y: 0, width: bounds.width - o.x * 2, height: backgroundHeight)
        let shape = NSBezierPath(roundedRect: rowRect, xRadius: ConsoleTheme.rowCornerRadius,
                                 yRadius: ConsoleTheme.rowCornerRadius)
        if let fill = model.fill {
            fill.setFill()
            shape.fill()
        }
        if let outline = model.outline {
            outline.setStroke()
            let inset = NSBezierPath(roundedRect: rowRect.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: ConsoleTheme.rowCornerRadius, yRadius: ConsoleTheme.rowCornerRadius)
            inset.lineWidth = 1
            inset.stroke()
        }

        // The class of line, down the left edge.
        let bar = CGRect(x: o.x + ConsoleRowGeometry.padding, y: ConsoleRowGeometry.padding,
                         width: ConsoleRowGeometry.indicatorWidth,
                         height: backgroundHeight - ConsoleRowGeometry.padding * 2)
        model.indicatorColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()

        // Faded by the context, not by the color: tertiary label color is
        // already partly transparent, and giving it an alpha of its own made
        // the time solid black.
        let stamp = NSAttributedString(string: model.timestamp, attributes: [
            .font: model.timestampFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        context.saveGState()
        context.setAlpha(model.alpha * model.timestampAlpha)
        stamp.draw(at: geometry.timestampRect.origin.applying(.init(translationX: o.x, y: o.y)))
        context.restoreGState()

        for (item, rect) in zip(model.header, geometry.headerRects) {
            draw(item, in: rect.offsetBy(dx: o.x, dy: o.y))
        }

        if let symbol = model.symbol, let rect = geometry.symbolRect,
           let image = ConsoleSymbolCache.image(symbol.name, pointSize: model.symbolPointSize,
                                                weight: .regular, color: .secondaryLabelColor) {
            let r = rect.offsetBy(dx: o.x, dy: o.y)
            let size = image.size
            image.draw(in: CGRect(x: r.minX + (r.width - size.width) / 2, y: r.minY + (r.height - size.height) / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        var y = geometry.expansionTop
        for line in model.expansion {
            line.draw(at: CGPoint(x: o.x + ConsoleRowGeometry.padding + 20, y: y))
            y += geometry.expansionLineHeight
        }
    }

    private func draw(_ item: ConsoleHeaderItem, in rect: CGRect) {
        let textColor: NSColor
        switch item.style {
        case .chip(prominent: true): textColor = .white
        default: textColor = item.color
        }
        switch item.style {
        case .chip(let prominent):
            (prominent ? item.color.withAlphaComponent(0.9) : item.color.withAlphaComponent(0.14)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        case .tag:
            item.color.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        case .badge:
            item.color.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        case .plain, .callsign, .icon:
            break
        }

        let padding: NSSize
        switch item.style {
        case .chip, .tag: padding = ConsoleHeaderItem.chipPadding
        case .badge: padding = ConsoleHeaderItem.badgePadding
        default: padding = .zero
        }
        var x = rect.minX + padding.width
        let textHeight = ceil(item.font.ascender - item.font.descender + item.font.leading)
        let textTop = rect.minY + padding.height

        if item.style == .tag {
            let dot = CGRect(x: x, y: rect.midY - ConsoleHeaderItem.dotSize / 2,
                             width: ConsoleHeaderItem.dotSize, height: ConsoleHeaderItem.dotSize)
            item.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            x = dot.maxX + ConsoleHeaderItem.iconGap
        }
        if let name = item.systemImage,
           let image = ConsoleSymbolCache.image(name, pointSize: item.symbolPointSize,
                                                weight: .semibold, color: textColor) {
            let size = image.size
            let imageRect = CGRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += ceil(item.symbolPointSize + 1) + (item.text.isEmpty ? 0 : ConsoleHeaderItem.iconGap)
        }
        if !item.text.isEmpty {
            let text = NSAttributedString(string: item.text, attributes: [.font: item.font, .foregroundColor: textColor])
            text.draw(at: CGPoint(x: x, y: textTop + (rect.height - padding.height * 2 - textHeight) / 2))
        }
    }

    // MARK: Interaction

    private func headerItem(at point: NSPoint) -> ConsoleHeaderItem? {
        guard let model, let geometry else { return nil }
        for (item, rect) in zip(model.header, geometry.headerRects)
        where rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -2).contains(point) {
            return item
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let call = headerItem(at: point)?.callsign, let onIdentity = actions.onIdentity {
            onIdentity(call)
            return
        }
        if model?.isExpandable == true, let lineID {
            actions.toggleExpanded(lineID)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let call = headerItem(at: point)?.callsign {
            menu.addItem(ClosureMenuItem("Show Profile") { [actions] in (actions.onIdentityMenu ?? actions.onIdentity)?(call) })
            menu.addItem(ClosureMenuItem("Quick Look") { [actions] in actions.onIdentity?(call) })
            if let qrz = QRZLink.url(for: call) {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(QRZLink.title(for: call)) { NSWorkspace.shared.open(qrz) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Copy Callsign") { ClipboardWriter.copy(call) })
            return menu
        }
        guard let model else { return nil }
        menu.addItem(ClosureMenuItem("Copy Line") { ClipboardWriter.copy(model.copyText) })
        return menu
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let model, let geometry, actions.onIdentity != nil else { return }
        for (item, rect) in zip(model.header, geometry.headerRects) where item.callsign != nil {
            addCursorRect(rect.offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
        }
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        guard let model, let geometry else { return }
        let o = origin
        addToolTip(geometry.timestampRect.offsetBy(dx: o.x, dy: o.y), owner: model.timestamp as NSString, userData: nil)
        let bar = CGRect(x: o.x, y: 0, width: ConsoleRowGeometry.contentLeft - 2, height: geometry.height)
        addToolTip(bar, owner: model.indicatorHelp as NSString, userData: nil)
        for (item, rect) in zip(model.header, geometry.headerRects) {
            if let help = item.help { addToolTip(rect.offsetBy(dx: o.x, dy: o.y), owner: help as NSString, userData: nil) }
        }
        if let symbol = model.symbol, let rect = geometry.symbolRect {
            addToolTip(rect.offsetBy(dx: o.x, dy: o.y), owner: symbol.help as NSString, userData: nil)
        }
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        if let name = ConsoleFileLink.name(from: url), let onFileName = actions.onFileName {
            onFileName(name)
            return true
        }
        if let call = ConsoleCallsignLink.callsign(from: url) {
            actions.onIdentity?(call)
            return true
        }
        // Anything else is an ordinary link: the system opens it.
        return false
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// "Today", "Yesterday" or the date, between two rules.
final class ConsoleDayCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConsoleDayCell")
    static let height: CGFloat = 26
    private var label = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func configure(date: Date) {
        label = DaySeparatorView.label(for: date)
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        let size = text.size()
        let inset = ConsoleLineCellView.horizontalInset
        let center = bounds.midX
        let textRect = CGRect(x: center - size.width / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
        text.draw(at: textRect.origin)
        NSColor.separatorColor.setFill()
        let y = floor(bounds.midY)
        NSRect(x: inset, y: y, width: max(textRect.minX - 8 - inset, 0), height: 1).fill()
        NSRect(x: textRect.maxX + 8, y: y, width: max(bounds.width - inset - textRect.maxX - 8, 0), height: 1).fill()
    }
}

/// The message going out, as the last row (finding 39). SwiftUI, hosted:
/// there is only ever one.
final class ConsoleSendStatusCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConsoleSendStatusCell")
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(status: InlineSendStatus, fontSize: Double) {
        host.rootView = AnyView(InlineSendStatusRow(status: status, fontSize: fontSize))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        host.frame = bounds.insetBy(dx: ConsoleLineCellView.horizontalInset, dy: 0)
    }

    /// How tall it is at a width.
    static func height(status: InlineSendStatus, fontSize: Double, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: InlineSendStatusRow(status: status, fontSize: fontSize)
            .frame(width: max(width - ConsoleLineCellView.horizontalInset * 2, 40)))
        return ceil(host.fittingSize.height) + 4
    }
}
#endif
