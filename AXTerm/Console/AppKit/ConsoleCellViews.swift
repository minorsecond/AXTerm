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

/// Text for selecting: put over one row when someone clicks into its
/// message (`ConsoleNSTableView.beginSelection`), and taken away again.
///
/// Rows never hold one. Changing a text view's text tells accessibility
/// clients its selection moved, and a client that then asks the table for its
/// rows while the table is building one makes NSTableView throw (2026-10-10).
final class ConsoleSelectionTextView: NSTextView {
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

    /// Called when focus moves on, so the table can take the overlay away.
    var onResign: (() -> Void)?

    /// A selection belongs to the row being read; moving on ends it.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    override var acceptsFirstResponder: Bool { true }
}

/// Lays out and draws a row's message, configured exactly as the
/// measurer is (`ConsoleTextMeasurer`), so the text fills the height measured
/// for it. Belongs to no view, so setting its text tells nobody anything.
@MainActor
final class ConsoleMessageText {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    func set(_ text: NSAttributedString, width: CGFloat) {
        storage.setAttributedString(text)
        setWidth(width)
    }

    func setWidth(_ width: CGFloat) {
        let size = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        if container.size != size { container.size = size }
    }

    func draw(at origin: CGPoint) {
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// Where each link sits, relative to the text's origin.
    func linkRects() -> [(rect: NSRect, url: URL)] {
        var result: [(NSRect, URL)] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: container) { rect, _ in
                result.append((rect, url))
            }
        }
        return result
    }

    /// The link under a point relative to the text's origin.
    func link(at point: NSPoint) -> URL? {
        linkRects().first { $0.rect.contains(point) }?.url
    }

    /// The text with its links drawn as links: underlined, in the link color.
    static func styled(_ message: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: message)
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value != nil else { return }
            out.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                               .foregroundColor: NSColor.linkColor], range: range)
        }
        return out
    }
}

/// One console line, drawn directly rather than built from views.
///
/// Rows are reused as the table scrolls; configuring one swaps its model and
/// redraws. Everything is drawn, the message included; selecting text puts a
/// text view over the row for as long as it is wanted.
final class ConsoleLineCellView: NSTableCellView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("ConsoleLineCell")
    /// Room each side, as the SwiftUI console's content padding gave.
    static let horizontalInset: CGFloat = 16

    private(set) var lineID: UUID?
    private var model: ConsoleRowModel?
    private var measurements: ConsoleRowMeasurements?
    private var geometry: ConsoleRowGeometry?
    private var actions = ConsoleTableActions()
    private let text = ConsoleMessageText()
    /// The message as drawn, links styled; what a selection overlay shows.
    private(set) var displayedMessage = NSAttributedString()
    /// While a selection overlay covers this row's message, the row leaves
    /// the message to it.
    var hidesMessage = false {
        didSet { if hidesMessage != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
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
        hidesMessage = false
        displayedMessage = ConsoleMessageText.styled(model.message)
        text.set(displayedMessage, width: geometry.messageRect.width)
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
        text.setWidth(geometry.messageRect.width)
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        rebuildToolTips()
    }

    private var origin: CGPoint { CGPoint(x: Self.horizontalInset, y: 0) }

    /// Where the message sits in this view.
    var messageFrame: NSRect {
        geometry.map { $0.messageRect.offsetBy(dx: origin.x, dy: origin.y) } ?? .zero
    }

    /// Where each link sits in this view.
    var linkRects: [NSRect] {
        let frame = messageFrame
        return text.linkRects().map { $0.rect.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    /// The link under a point in this view.
    func link(at point: NSPoint) -> URL? {
        let frame = messageFrame
        guard frame.contains(point) else { return nil }
        return text.link(at: NSPoint(x: point.x - frame.minX, y: point.y - frame.minY))
    }

    /// Follows the link under a point, if there is one.
    func open(at point: NSPoint) -> Bool {
        guard let url = link(at: point) else { return false }
        if !follow(url) { NSWorkspace.shared.open(url) }
        return true
    }

    /// Handles an in-app link; false for an ordinary one the system opens.
    private func follow(_ url: URL) -> Bool {
        if let name = ConsoleFileLink.name(from: url), let onFileName = actions.onFileName {
            onFileName(name)
            return true
        }
        if let call = ConsoleCallsignLink.callsign(from: url) {
            actions.onIdentity?(call)
            return true
        }
        return false
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

        if !hidesMessage {
            text.draw(at: geometry.messageRect.origin.applying(.init(translationX: o.x, y: o.y)))
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

    /// What a click on this row does: open a callsign in the header, or
    /// fold a long line open. False when the row has nothing to do with it.
    @discardableResult
    func handleClick(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if let call = headerItem(at: point)?.callsign, let onIdentity = actions.onIdentity {
            onIdentity(call)
            return true
        }
        if model?.isExpandable == true, let lineID {
            actions.toggleExpanded(lineID)
            return true
        }
        return false
    }

    /// A click the row does not handle goes on to the table, which handles
    /// it without handing it back: the two used to pass it between them
    /// until the stack ran out (remote access test, 2026-10-11).
    override func mouseDown(with event: NSEvent) {
        if handleClick(event) { return }
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
        guard let model, let geometry else { return }
        addCursorRect(messageFrame, cursor: .iBeam)
        for rect in linkRects { addCursorRect(rect, cursor: .pointingHand) }
        guard actions.onIdentity != nil else { return }
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
        if let help = model.messageHelp {
            addToolTip(messageFrame, owner: help as NSString, userData: nil)
        }
    }

    // MARK: Links

    /// A link clicked in the selection overlay over this row.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        // Anything not ours is an ordinary link: the system opens it.
        return follow(url)
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
