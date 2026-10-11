import Foundation

/// How to turn one list of row ids into the next without reloading.
///
/// The console grows at the bottom, trims its oldest lines at the top once
/// full, and sometimes swaps its last row (the send status). Each update is
/// therefore: rows dropped from the front, a run kept, rows dropped from the
/// back and rows added after the kept run. Anything else keeps nothing, and
/// the table reloads.
nonisolated enum ConsoleTableDiff {
    struct Plan: Equatable {
        var removeFront = 0
        var keep = 0
        var removeBack = 0
        var insertBack = 0
    }

    static func plan<ID: Equatable>(old: [ID], new: [ID]) -> Plan {
        guard let first = new.first else { return Plan(removeBack: old.count) }
        guard let start = old.firstIndex(of: first) else {
            return Plan(removeBack: old.count, insertBack: new.count)
        }
        var keep = 0
        while start + keep < old.count, keep < new.count, old[start + keep] == new[keep] { keep += 1 }
        return Plan(removeFront: start, keep: keep,
                    removeBack: old.count - start - keep, insertBack: new.count - keep)
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// One row of the console table.
enum ConsoleTableItem {
    case day(Date)
    case line(ConsoleLineGroup, run: ConsoleTimestampRuler.RunPosition, beaconRepeat: BeaconRepeat?)
    case sendStatus(InlineSendStatus)

    enum ID: Hashable {
        case day(Date)
        case line(UUID)
        case sendStatus
    }

    var id: ID {
        switch self {
        case .day(let date): return .day(date)
        case .line(let group, _, _): return .line(group.id)
        case .sendStatus: return .sendStatus
        }
    }

    /// Changes whenever the row would draw differently, with the console's
    /// settings unchanged.
    var version: Int {
        var hasher = Hasher()
        switch self {
        case .day(let date):
            hasher.combine(date)
        case .line(let group, let run, let beaconRepeat):
            hasher.combine(group.id)
            hasher.combine(group.duplicateCount)
            hasher.combine(run)
            hasher.combine(beaconRepeat?.ordinal)
            hasher.combine(beaconRepeat?.since)
        case .sendStatus(let status):
            hasher.combine(String(describing: status))
        }
        return hasher.finalize()
    }
}

/// The table itself: it lets a click reach the row's own handling, and the
/// message's text view, instead of turning it into a row selection.
final class ConsoleNSTableView: NSTableView {
    /// The text view over the row being selected in, if any. A subview of the
    /// table rather than of the row's cell, so it stays over the right row
    /// when cells are reused as the table scrolls.
    private(set) weak var selectionOverlay: ConsoleSelectionTextView?
    private var selectionRow: Int?

    /// Puts a selectable copy of a row's message over it. Only ever from a
    /// click, never while the table is building rows (`ConsoleSelectionTextView`).
    @discardableResult
    func beginSelection(inRow row: Int) -> NSTextView? {
        endSelection()
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? ConsoleLineCellView else { return nil }
        let overlay = ConsoleSelectionTextView()
        overlay.textStorage?.setAttributedString(cell.displayedMessage)
        overlay.frame = cell.convert(cell.messageFrame, to: self)
        overlay.delegate = cell
        overlay.onResign = { [weak self, weak overlay] in
            // After focus has finished moving, not during it.
            DispatchQueue.main.async {
                guard let self, let overlay, self.selectionOverlay === overlay else { return }
                self.endSelection()
            }
        }
        addSubview(overlay, positioned: .above, relativeTo: nil)
        cell.hidesMessage = true
        selectionOverlay = overlay
        selectionRow = row
        return overlay
    }

    /// Takes the overlay away and gives the row its message back.
    func endSelection() {
        if let row = selectionRow, row < numberOfRows,
           let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? ConsoleLineCellView {
            cell.hidesMessage = false
        }
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
        selectionRow = nil
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? ConsoleLineCellView {
            let inCell = cell.convert(event.locationInWindow, from: nil)
            if cell.open(at: inCell) {
                return
            }
            if cell.messageFrame.contains(inCell), let overlay = beginSelection(inRow: row) {
                window?.makeFirstResponder(overlay)
                overlay.mouseDown(with: event)
            } else {
                endSelection()
                // The row's own handling only: its mouseDown would pass an
                // unhandled click back up to this table.
                cell.handleClick(event)
            }
            return
        }
        endSelection()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? ConsoleLineCellView
        else { return nil }
        let inCell = cell.convert(event.locationInWindow, from: nil)
        if let overlay = selectionOverlay, selectionRow == row, cell.messageFrame.contains(inCell),
           let menu = overlay.menu(for: event) {
            if let rowMenu = cell.menu(for: event), let copyLine = rowMenu.items.first {
                rowMenu.removeItem(copyLine)
                menu.insertItem(copyLine, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
            return menu
        }
        return cell.menu(for: event)
    }
}

/// The Mac's console: an AppKit table that reuses a screenful of rows.
///
/// The SwiftUI console built every row from scratch as it scrolled into view
/// and threw it away as it left, and scrolling stuttered with the main thread
/// all but saturated (2026-10-10). Here the table keeps a handful of row
/// views and swaps what they show; heights are worked out once per row and
/// width, and only a message that wraps is ever laid out to find its height.
struct ConsoleTableView: NSViewRepresentable {
    let items: [ConsoleTableItem]
    let environment: ConsoleRowEnvironment
    let fileNameIndex: FileNameIndex?
    let actions: ConsoleTableActions
    /// Bumped whenever `items` changes. SwiftUI asks for an update far more
    /// often than the lines change, and comparing a whole console's rows on
    /// each ask was a steady cost.
    let revision: Int
    @Binding var isFollowing: Bool
    let autoScroll: Bool
    let scrollToBottomToken: Int

    static let verticalInset: CGFloat = 16

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ConsoleNSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: ConsoleTheme.rowSpacing)
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.gridStyleMask = []
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsMultipleSelection = false
        table.focusRingType = .none
        table.setAccessibilityLabel("Terminal")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("console"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        context.coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(items: items, revision: revision, environment: environment,
                                   fileNameIndex: fileNameIndex, actions: actions, isFollowing: $isFollowing,
                                   autoScroll: autoScroll, scrollToBottomToken: scrollToBottomToken)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// What is known about one row. Its size comes from a model built
        /// without links, which is all measuring needs; the full model is built
        /// only when the row comes on screen. A station newly heard changes
        /// which words are links, so it rebuilds models but no heights.
        private struct CachedRow {
            var layoutVersion: Int
            var measurements: ConsoleRowMeasurements
            var wrapsBelow: Bool
            var expansionLines: Int
            var geometry: (width: CGFloat, value: ConsoleRowGeometry)?
            var model: (version: Int, value: ConsoleRowModel)?
        }

        private weak var table: NSTableView?
        private weak var scroll: NSScrollView?
        private(set) var items: [ConsoleTableItem] = []
        private var layoutVersion: Int?
        private var decorationVersion: Int?
        private var environment = ConsoleRowEnvironment()
        private var fileNameIndex: FileNameIndex?
        private var actions = ConsoleTableActions()
        private var expanded: Set<UUID> = []
        private var rows: [UUID: CachedRow] = [:]
        private var sendStatusHeight: (width: CGFloat, version: Int, height: CGFloat)?
        private var lastWidth: CGFloat = 0

        private var followingBinding: Binding<Bool>?
        private var isFollowing = true
        /// Follow changes sent to SwiftUI and not yet applied there. While
        /// any are in flight the binding still holds the old value, and
        /// reading it back would undo the change.
        private var pendingFollowingPublishes = 0
        private var revision: Int?
        private var autoScroll = true
        private var lastToken: Int?
        private var lastGeometry: PacketListFollow.Geometry?
        private var userIsScrolling = false
        private var isProgrammaticScroll = false
        private var observers: [NSObjectProtocol] = []
        /// The row the reader was last seen on, taken whenever the view moves.
        /// A width change restores this rather than measuring afresh: by the
        /// time the table reports its new width, AppKit may already have
        /// shifted the view.
        private var readerAnchor: Anchor?
        /// After a width change, AppKit keeps settling the view for a moment
        /// and can shift it more than once. Until this passes, any shift the
        /// reader did not make puts their row back.
        private var settlingAnchor: (anchor: Anchor, until: Date)?

        func attach(table: NSTableView, scroll: NSScrollView) {
            self.table = table
            self.scroll = scroll
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.clipMoved() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.clipResized() }
                },
                center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.userIsScrolling = true
                        self?.settlingAnchor = nil
                    }
                },
                center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.userIsScrolling = false }
                },
            ]
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        // MARK: Updates

        func update(items newItems: [ConsoleTableItem], revision newRevision: Int,
                    environment env: ConsoleRowEnvironment,
                    fileNameIndex: FileNameIndex?, actions: ConsoleTableActions,
                    isFollowing binding: Binding<Bool>, autoScroll: Bool, scrollToBottomToken: Int) {
            guard let table else { return }
            var actions = actions
            actions.toggleExpanded = { [weak self] id in self?.toggleExpanded(id) }
            self.actions = actions
            self.fileNameIndex = fileNameIndex
            self.autoScroll = autoScroll
            followingBinding = binding
            // Only a change SwiftUI made itself (the jump button) is taken
            // from the binding; one of ours still on its way is not.
            if pendingFollowingPublishes == 0, binding.wrappedValue != isFollowing {
                isFollowing = binding.wrappedValue
            }

            let sticks = isFollowing && autoScroll
            let layoutChanged = env.layoutVersion != layoutVersion
            let decorationChanged = env.decorationVersion != decorationVersion
            let itemsChanged = newRevision != revision
            let tokenChanged = scrollToBottomToken != lastToken
            guard itemsChanged || layoutChanged || decorationChanged || tokenChanged else { return }
            revision = newRevision
            environment = env
            layoutVersion = env.layoutVersion
            decorationVersion = env.decorationVersion
            if lastWidth == 0 { lastWidth = contentWidth }

            let anchor = sticks ? nil : visibleAnchor()
            // A selection is over one row's text as it was; rows are about to
            // change, so it goes first.
            (table as? ConsoleNSTableView)?.endSelection()
            // Rows changing under the view move it; that is not the reader.
            isProgrammaticScroll = true
            if layoutChanged || table.numberOfRows == 0 {
                rows.removeAll()
                items = newItems
                table.reloadData()
            } else if itemsChanged {
                apply(newItems, to: table)
            }
            if !layoutChanged, decorationChanged {
                // Only what is on screen; the rest rebuilds as it scrolls in.
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                     columnIndexes: IndexSet(integer: 0))
                }
            }

            isProgrammaticScroll = false

            if tokenChanged {
                let first = lastToken == nil
                lastToken = scrollToBottomToken
                scrollToEnd(animated: !first)
            } else if sticks {
                if itemsChanged || layoutChanged { scrollToEnd(animated: false) }
            } else if let anchor {
                restore(anchor)
            }
            lastGeometry = currentGeometry()
        }

        private func apply(_ newItems: [ConsoleTableItem], to table: NSTableView) {
            let plan = ConsoleTableDiff.plan(old: items.map(\.id), new: newItems.map(\.id))
            guard plan.keep > 0 else {
                items = newItems
                pruneCache()
                table.reloadData()
                return
            }
            var changed = IndexSet()
            for index in 0..<plan.keep where items[plan.removeFront + index].version != newItems[index].version {
                changed.insert(index)
            }
            items = newItems
            if plan.removeFront > 0 || plan.removeBack > 0 || plan.insertBack > 0 {
                table.beginUpdates()
                if plan.removeFront > 0 {
                    table.removeRows(at: IndexSet(integersIn: 0..<plan.removeFront), withAnimation: [])
                }
                if plan.removeBack > 0 {
                    table.removeRows(at: IndexSet(integersIn: plan.keep..<(plan.keep + plan.removeBack)), withAnimation: [])
                }
                if plan.insertBack > 0 {
                    table.insertRows(at: IndexSet(integersIn: plan.keep..<(plan.keep + plan.insertBack)), withAnimation: [])
                }
                table.endUpdates()
            }
            if !changed.isEmpty {
                table.noteHeightOfRows(withIndexesChanged: changed)
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
            if plan.removeFront > 0 || plan.removeBack > 0 { pruneCache() }
        }

        /// Forget rows that have left the console.
        private func pruneCache() {
            let live = Set(items.compactMap { item -> UUID? in
                if case .line(let group, _, _) = item { return group.id }
                return nil
            })
            if rows.count > live.count { rows = rows.filter { live.contains($0.key) } }
            expanded.formIntersection(live)
        }

        private func toggleExpanded(_ id: UUID) {
            guard let table, let index = items.firstIndex(where: { $0.id == .line(id) }) else { return }
            (table as? ConsoleNSTableView)?.endSelection()
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
            }
            table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        }

        // MARK: Rows

        private var contentWidth: CGFloat {
            let width = table?.tableColumns.first?.width ?? table?.bounds.width ?? 0
            return max(width - ConsoleLineCellView.horizontalInset * 2, 120)
        }

        private func rowLayoutVersion(itemVersion: Int, id: UUID) -> Int {
            var hasher = Hasher()
            hasher.combine(itemVersion)
            hasher.combine(expanded.contains(id))
            return hasher.finalize()
        }

        /// The row's measurements, from a model built without links.
        private func cachedRow(at index: Int) -> (UUID, CachedRow)? {
            guard items.indices.contains(index), case .line(let group, let run, let beaconRepeat) = items[index]
            else { return nil }
            let version = rowLayoutVersion(itemVersion: items[index].version, id: group.id)
            if let row = rows[group.id], row.layoutVersion == version { return (group.id, row) }
            let model = ConsoleRowModel.make(group: group, timestampRun: run, beaconRepeat: beaconRepeat,
                                             isExpanded: expanded.contains(group.id), environment: environment,
                                             fileNameIndex: fileNameIndex, decorated: false)
            let row = CachedRow(layoutVersion: version, measurements: ConsoleRowMeasurements(model: model),
                                wrapsBelow: model.wrapsBelow, expansionLines: model.expansion.count)
            rows[group.id] = row
            return (group.id, row)
        }

        /// The full model, with links, for a row on screen.
        private func model(at index: Int) -> ConsoleRowModel? {
            guard let (id, row) = cachedRow(at: index),
                  case .line(let group, let run, let beaconRepeat) = items[index] else { return nil }
            let version = environment.decorationVersion ^ row.layoutVersion
            if let model = row.model, model.version == version { return model.value }
            let model = ConsoleRowModel.make(group: group, timestampRun: run, beaconRepeat: beaconRepeat,
                                             isExpanded: expanded.contains(id), environment: environment,
                                             fileNameIndex: fileNameIndex)
            rows[id]?.model = (version, model)
            return model
        }

        private func geometry(at index: Int) -> ConsoleRowGeometry? {
            guard let (id, row) = cachedRow(at: index) else { return nil }
            let width = contentWidth
            if let cached = row.geometry, cached.width == width { return cached.value }
            let geometry = ConsoleRowGeometry.layout(
                width: width, measurements: row.measurements, wrapsBelow: row.wrapsBelow,
                expansionLines: row.expansionLines) { [weak self] textWidth in
                    // Wrapped text needs the real string; links change nothing here.
                    guard let self, let model = self.model(at: index) else { return 0 }
                    return ConsoleTextMeasurer.shared.size(of: model.message, width: textWidth).height
                }
            rows[id]?.geometry = (width, geometry)
            return geometry
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard items.indices.contains(row) else { return 1 }
            switch items[row] {
            case .day:
                return ConsoleDayCellView.height
            case .sendStatus(let status):
                let width = contentWidth + ConsoleLineCellView.horizontalInset * 2
                let version = items[row].version
                if let cached = sendStatusHeight, cached.width == width, cached.version == version {
                    return cached.height
                }
                let height = ConsoleSendStatusCellView.height(status: status, fontSize: environment.fontSize, width: width)
                sendStatusHeight = (width, version, height)
                return height
            case .line:
                return geometry(at: row)?.height ?? 20
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            switch items[row] {
            case .day(let date):
                let cell = tableView.makeView(withIdentifier: ConsoleDayCellView.identifier, owner: nil)
                    as? ConsoleDayCellView ?? ConsoleDayCellView(frame: .zero)
                cell.configure(date: date)
                return cell
            case .sendStatus(let status):
                let cell = tableView.makeView(withIdentifier: ConsoleSendStatusCellView.identifier, owner: nil)
                    as? ConsoleSendStatusCellView ?? ConsoleSendStatusCellView(frame: .zero)
                cell.configure(status: status, fontSize: environment.fontSize)
                return cell
            case .line(let group, _, _):
                guard let model = model(at: row), let geometry = geometry(at: row),
                      let measurements = rows[group.id]?.measurements else { return nil }
                let cell = tableView.makeView(withIdentifier: ConsoleLineCellView.identifier, owner: nil)
                    as? ConsoleLineCellView ?? ConsoleLineCellView(frame: .zero)
                cell.configure(lineID: group.id, model: model, measurements: measurements,
                               geometry: geometry, actions: actions)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        // MARK: Scrolling

        private func documentBottom() -> CGFloat {
            guard let table, table.numberOfRows > 0 else { return 0 }
            return table.rect(ofRow: table.numberOfRows - 1).maxY
        }

        private func currentGeometry() -> PacketListFollow.Geometry? {
            guard let scroll else { return nil }
            let bounds = scroll.contentView.bounds
            return PacketListFollow.Geometry(contentHeight: documentBottom(), visibleMinY: bounds.minY,
                                             visibleHeight: bounds.height, visibleWidth: bounds.width)
        }

        private func scrollToEnd(animated: Bool) {
            guard let scroll, let table, table.numberOfRows > 0 else { return }
            let clip = scroll.contentView
            let insets = scroll.contentInsets
            let target = max(documentBottom() - clip.bounds.height + insets.bottom, -insets.top)
            guard abs(clip.bounds.minY - target) > 0.5 else { return }
            isProgrammaticScroll = true
            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    context.allowsImplicitAnimation = true
                    clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let scroll = self.scroll else { return }
                        scroll.reflectScrolledClipView(scroll.contentView)
                        self.isProgrammaticScroll = false
                        self.lastGeometry = self.currentGeometry()
                    }
                })
            } else {
                clip.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(clip)
                isProgrammaticScroll = false
                lastGeometry = currentGeometry()
            }
        }

        private struct Anchor {
            let id: ConsoleTableItem.ID
            let offset: CGFloat
        }

        /// The first row on screen and how far it sits from the top, so the
        /// view can stay put while rows change around it.
        private func visibleAnchor() -> Anchor? {
            guard let table, let scroll, table.numberOfRows > 0 else { return nil }
            let bounds = scroll.contentView.bounds
            let range = table.rows(in: bounds)
            guard range.length > 0, items.indices.contains(range.location) else { return nil }
            let row = range.location
            return Anchor(id: items[row].id, offset: table.rect(ofRow: row).minY - bounds.minY)
        }

        private func restore(_ anchor: Anchor) {
            guard let table, let scroll, let index = items.firstIndex(where: { $0.id == anchor.id }) else { return }
            readerAnchor = anchor
            let clip = scroll.contentView
            let target = table.rect(ofRow: index).minY - anchor.offset
            guard abs(clip.bounds.minY - target) > 0.5 else { return }
            isProgrammaticScroll = true
            clip.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(clip)
            isProgrammaticScroll = false
            lastGeometry = currentGeometry()
        }

        private func setFollowing(_ following: Bool) {
            guard following != isFollowing else { return }
            isFollowing = following
            let binding = followingBinding
            pendingFollowingPublishes += 1
            DispatchQueue.main.async { [weak self] in
                binding?.wrappedValue = following
                self?.pendingFollowingPublishes -= 1
            }
        }

        /// The reader scrolled, or something moved the view.
        private func clipMoved() {
            guard let new = currentGeometry() else { return }
            let old = lastGeometry
            defer {
                lastGeometry = new
                // Only a move the reader made: the same content in the same
                // view. AppKit shifting the view while rows change size is
                // not where the reader is.
                if !isProgrammaticScroll, let old,
                   userIsScrolling || (old.contentHeight == new.contentHeight
                                       && old.visibleWidth == new.visibleWidth
                                       && old.visibleHeight == new.visibleHeight) {
                    readerAnchor = visibleAnchor()
                }
            }
            guard !isProgrammaticScroll, let old else { return }
            if let settling = settlingAnchor {
                if userIsScrolling || Date() > settling.until {
                    settlingAnchor = nil
                } else {
                    restore(settling.anchor)
                    return
                }
            }
            let decision = PacketListFollow.decide(from: old, to: new, isFollowing: isFollowing,
                                                   userIsScrolling: userIsScrolling)
            setFollowing(decision.isFollowing)
            if decision.scrollToNewest, autoScroll { scrollToEnd(animated: false) }
        }

        /// The window or the sidebar changed the console's size. A new width
        /// changes every row's wrap, so every height is asked for again; the
        /// view then stays at the bottom or on the row it showed.
        private func clipResized() {
            widthMayHaveChanged()
            if isFollowing && autoScroll { scrollToEnd(animated: false) }
            lastGeometry = currentGeometry()
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            widthMayHaveChanged()
        }

        /// A new width changes every row's wrap, so every height is asked for
        /// again and the rows on screen are laid out anew. The view then stays
        /// at the bottom or on the row it showed. The table moving the view
        /// while it settles is not the reader scrolling, so it is not taken
        /// for one.
        private func widthMayHaveChanged() {
            guard let table else { return }
            let width = contentWidth
            guard width != lastWidth, !items.isEmpty else { return }
            lastWidth = width
            (table as? ConsoleNSTableView)?.endSelection()
            let sticks = isFollowing && autoScroll
            let anchor = sticks ? nil : (readerAnchor ?? visibleAnchor())
            isProgrammaticScroll = true
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
            // Settle the new heights now, so the row rects used to put the
            // reader back are the new ones.
            table.tile()
            table.enumerateAvailableRowViews { rowView, row in
                guard let cell = rowView.view(atColumn: 0) as? ConsoleLineCellView,
                      let geometry = self.geometry(at: row) else { return }
                cell.update(geometry: geometry)
            }
            isProgrammaticScroll = false
            if sticks {
                scrollToEnd(animated: false)
            } else if let anchor {
                restore(anchor)
                // AppKit finishes settling the resized view after this
                // returns and can nudge it a few points; hold the reader's row
                // through that, and once more on the next pass.
                settlingAnchor = (anchor, Date().addingTimeInterval(0.25))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.isFollowing, self.settlingAnchor != nil else { return }
                        self.restore(anchor)
                    }
                }
            }
            lastGeometry = currentGeometry()
        }
    }
}
#endif
