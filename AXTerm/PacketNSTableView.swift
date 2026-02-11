//
//  PacketNSTableView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import AppKit
import SwiftUI
import os

struct PacketNSTableView: NSViewRepresentable {
    struct Constants {
        static let autosaveName = "PacketTable"
        static let defaultColumnOrder: [ColumnIdentifier] = [.time, .from, .to, .via, .type, .info]
        static let infoColumnIdentifier: ColumnIdentifier = .info
    }

    enum ColumnIdentifier: String, CaseIterable {
        case time
        case from
        case to
        case via
        case type
        case info
    }

    let packets: [Packet]
    @Binding var selection: Set<Packet.ID>
    @Binding var isAtBottom: Bool
    @Binding var followNewest: Bool
    let scrollToBottomToken: Int
    let onInspectSelection: () -> Void
    let onCopyInfo: (Packet) -> Void
    let onCopyRawHex: (Packet) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: $selection,
            isAtBottom: $isAtBottom,
            followNewest: $followNewest,
            onInspectSelection: onInspectSelection,
            onCopyInfo: onCopyInfo,
            onCopyRawHex: onCopyRawHex
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.autosaveName = Constants.autosaveName
        tableView.autosaveTableColumns = true
        tableView.menu = contextMenu(for: context.coordinator)
        tableView.autoresizingMask = [.width, .height]
        tableView.translatesAutoresizingMaskIntoConstraints = true

        #if DEBUG
        resetAutosavedColumnsIfNeeded(for: tableView)
        #endif

        context.coordinator.attach(tableView: tableView)
        configureColumns(for: tableView)
        let initialRows = packets.map { PacketRowViewModel.fromPacket($0) }
        PacketNSTableView.sizeColumnsToFitContent(in: tableView, rows: initialRows)
        PacketNSTableView.expandInfoColumnToFill(in: tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        context.coordinator.attach(scrollView: scrollView)
        
        // Initial scroll to bottom if needed
        if context.coordinator.isAtBottom.wrappedValue {
             DispatchQueue.main.async {
                 if tableView.numberOfRows > 0 {
                     tableView.scrollRowToVisible(tableView.numberOfRows - 1)
                 }
             }
        }
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.enqueueUpdate(
            packets: packets,
            selection: selection,
            scrollToBottomToken: scrollToBottomToken
        )
    }

    private func configureColumns(for tableView: NSTableView) {
        if !tableView.tableColumns.isEmpty { return }

        let timeColumn = makeColumn(id: .time, title: "Time", minWidth: 70, width: 80, toolTip: "Received time")
        let fromColumn = makeColumn(id: .from, title: "From", minWidth: 80, width: 100, toolTip: "Source callsign")
        let toColumn = makeColumn(id: .to, title: "To", minWidth: 80, width: 100, toolTip: "Destination callsign")
        let viaColumn = makeColumn(id: .via, title: "Via", minWidth: 60, width: 120, toolTip: "Digipeater path")
        let typeColumn = makeColumn(id: .type, title: "Frame Type", minWidth: 60, width: 70, toolTip: "Classified frame type")
        let infoColumn = makeColumn(id: .info, title: "Info", minWidth: 200, width: 400, toolTip: "Decoded payload preview")
        infoColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(fromColumn)
        tableView.addTableColumn(toColumn)
        tableView.addTableColumn(viaColumn)
        tableView.addTableColumn(typeColumn)
        tableView.addTableColumn(infoColumn)
        // With .lastColumnOnlyAutoresizingStyle, the trailing column expands to fill
        // remaining width like Finder. Keep Info last to make it the expanding column.
    }

    private func makeColumn(id: ColumnIdentifier, title: String, minWidth: CGFloat, width: CGFloat, toolTip: String) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = title
        column.minWidth = minWidth
        column.width = width
        column.resizingMask = .userResizingMask
        column.headerToolTip = toolTip
        return column
    }

    private func contextMenu(for coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let inspectItem = NSMenuItem(title: "Inspect Packet", action: #selector(Coordinator.inspectFromMenu(_:)), keyEquivalent: "")
        inspectItem.target = coordinator
        menu.addItem(inspectItem)

        menu.addItem(.separator())

        let copyInfoItem = NSMenuItem(title: "Copy Info", action: #selector(Coordinator.copyInfoFromMenu(_:)), keyEquivalent: "")
        copyInfoItem.target = coordinator
        menu.addItem(copyInfoItem)

        let copyRawItem = NSMenuItem(title: "Copy Raw Hex", action: #selector(Coordinator.copyRawHexFromMenu(_:)), keyEquivalent: "")
        copyRawItem.target = coordinator
        menu.addItem(copyRawItem)

        return menu
    }

    #if DEBUG
    private func resetAutosavedColumnsIfNeeded(for tableView: NSTableView) {
        // Autosaved column widths can mask changes to autoresizingColumn. Use this
        // debug-only toggle to clear saved widths if the Info column stays narrow.
        let shouldResetAutosave = false
        guard shouldResetAutosave, let autosaveName = tableView.autosaveName else { return }
        let defaultsKey = "NSTableView Columns \(autosaveName)"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
    #endif

    private static func sizeColumnsToFitContent(in tableView: NSTableView, rows: [PacketRowViewModel]) {
        guard !tableView.tableColumns.isEmpty else { return }
        let measurements = PacketTableColumnSizer(rows: rows)
        for column in tableView.tableColumns {
            guard let identifier = ColumnIdentifier(rawValue: column.identifier.rawValue) else { continue }
            guard identifier != .info else { continue }
            let targetWidth = measurements.width(for: identifier)
            column.width = max(column.minWidth, targetWidth)
        }
    }

    private static func expandInfoColumnToFill(in tableView: NSTableView) {
        guard let infoColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == ColumnIdentifier.info.rawValue }) else {
            return
        }
        let totalSpacing = tableView.intercellSpacing.width * CGFloat(max(0, tableView.tableColumns.count - 1))
        let otherColumnsWidth = tableView.tableColumns
            .filter { $0 != infoColumn }
            .reduce(CGFloat.zero) { $0 + $1.width }
        let availableWidth = max(infoColumn.minWidth, tableView.bounds.width - otherColumnsWidth - totalSpacing)
        // Only expand; never shrink user-resized widths.
        if availableWidth > infoColumn.width {
            infoColumn.width = availableWidth
        }
    }
}

extension PacketNSTableView {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct PendingUpdate {
            let packets: [Packet]
            let selection: Set<Packet.ID>
            let scrollToBottomToken: Int
        }

        private enum RowUpdate {
            case none
            case insert(count: Int)
            case remove(range: Range<Int>)
            case reload
        }

        private let logger = Logger(subsystem: "AXTerm", category: "PacketTable")
        private let selection: Binding<Set<Packet.ID>>
        let isAtBottom: Binding<Bool> // Made internal to be accessible by makeNSView
        private let followNewest: Binding<Bool>
        private let onInspectSelection: () -> Void
        private let onCopyInfo: (Packet) -> Void
        private let onCopyRawHex: (Packet) -> Void

        private(set) var rows: [PacketRowViewModel] = []
        private(set) var packets: [Packet] = []
        private var isApplyingSelection = false
        private var lastContextRow: Int?
        private var lastScrollToBottomToken = 0
        private var scrollObserver: NSObjectProtocol?
        private var pendingUpdate: PendingUpdate?
        private var isProgrammaticUpdate = false
        private var isContextMenuTracking = false
        private var menuDidBeginObserver: NSObjectProtocol?
        private var menuDidEndObserver: NSObjectProtocol?
        private var scrollStateWorkItem: DispatchWorkItem?
        private var pendingIsAtBottom: Bool?
        private var lastPublishedIsAtBottom: Bool?
        private let rowUpdateScheduler = CoalescingScheduler(delay: .milliseconds(80))
        private let columnSizingScheduler = CoalescingScheduler(delay: .milliseconds(500))

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        init(
            selection: Binding<Set<Packet.ID>>,
            isAtBottom: Binding<Bool>,
            followNewest: Binding<Bool>,
            onInspectSelection: @escaping () -> Void,
            onCopyInfo: @escaping (Packet) -> Void,
            onCopyRawHex: @escaping (Packet) -> Void
        ) {
            self.selection = selection
            self.isAtBottom = isAtBottom
            self.followNewest = followNewest
            self.onInspectSelection = onInspectSelection
            self.onCopyInfo = onCopyInfo
            self.onCopyRawHex = onCopyRawHex
        }

        func enqueueUpdate(
            packets: [Packet],
            selection: Set<Packet.ID>,
            scrollToBottomToken: Int
        ) {
            #if DEBUG
            logger.debug("Packet table enqueue update (count: \(packets.count), token: \(scrollToBottomToken))")
            #endif
            pendingUpdate = PendingUpdate(
                packets: packets,
                selection: selection,
                scrollToBottomToken: scrollToBottomToken
            )
            rowUpdateScheduler.schedule { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.applyPendingUpdate()
                }
            }
        }

        func attach(tableView: NSTableView) {
            self.tableView = tableView
            observeMenuTracking(for: tableView.menu)
        }

        func attach(scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, let tableView = self.tableView else { return }
                self.updateIsAtBottom(in: tableView)
            }
        }

        func applySelection(_ selection: Set<Packet.ID>) {
            guard let tableView else { return }
            let mapper = PacketTableSelectionMapper(rows: rows)
            let desired = mapper.indexes(for: selection)
            guard desired != tableView.selectedRowIndexes else { return }
            isApplyingSelection = true
            tableView.selectRowIndexes(desired, byExtendingSelection: false)
            isApplyingSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let mapper = PacketTableSelectionMapper(rows: rows)
            let newSelection = mapper.selection(for: tableView.selectedRowIndexes)
            DispatchQueue.main.async { [weak self] in
                self?.selection.wrappedValue = newSelection
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, rows.indices.contains(row) else { return nil }
            let rowModel = rows[row]
            let identifier = tableColumn.identifier
            if identifier.rawValue == ColumnIdentifier.type.rawValue {
                return makeTypePillCell(for: identifier, row: rowModel)
            }

            let textField = makeTextField(for: identifier, row: rowModel)
            let cell = NSTableCellView()
            cell.identifier = identifier
            cell.textField = textField
            cell.addSubview(textField)
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 1),
                textField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -1)
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, menuFor event: NSEvent) -> NSMenu? {
            let clickedRow = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
            guard rows.indices.contains(clickedRow) else {
                lastContextRow = nil
                return nil
            }
            lastContextRow = clickedRow
            if !tableView.selectedRowIndexes.contains(clickedRow) {
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.rows.indices.contains(clickedRow) else { return }
                self.selection.wrappedValue = [self.rows[clickedRow].id]
            }
            return tableView.menu
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            activateRow(row)
        }

        @objc func inspectFromMenu(_ sender: Any?) {
            activateRow(lastContextRow)
        }

        @objc func copyInfoFromMenu(_ sender: Any?) {
            guard let packet = packetForContextAction() else { return }
            onCopyInfo(packet)
        }

        @objc func copyRawHexFromMenu(_ sender: Any?) {
            guard let packet = packetForContextAction() else { return }
            onCopyRawHex(packet)
        }

        private func packetForContextAction() -> Packet? {
            if let contextRow = lastContextRow, packets.indices.contains(contextRow) {
                return packets[contextRow]
            }
            guard let tableView else { return nil }
            let row = tableView.selectedRowIndexes.first ?? -1
            guard packets.indices.contains(row) else { return nil }
            return packets[row]
        }

        private func activateRow(_ row: Int?) {
            guard let tableView else { return }
            let resolvedRow = row ?? tableView.selectedRowIndexes.first
            guard let resolvedRow, rows.indices.contains(resolvedRow) else { return }
            let packetID = rows[resolvedRow].id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selection.wrappedValue = [packetID]
                self.onInspectSelection()
            }
        }

        private func firstVisiblePacketID(in tableView: NSTableView) -> Packet.ID? {
            let visibleRect = tableView.visibleRect
            let visibleRows = tableView.rows(in: visibleRect)
            guard visibleRows.length > 0 else { return nil }
            let index = Int(visibleRows.location)
            guard rows.indices.contains(index) else { return nil }
            return rows[index].id
        }

        private func updateScrollPosition(
            in tableView: NSTableView,
            anchorID: Packet.ID?,
            wasAtBottom: Bool,
            shouldScrollToBottom: Bool
        ) {
            let shouldAutoScroll = AutoScrollDecision.shouldAutoScroll(
                isUserAtTarget: wasAtBottom,
                followNewest: followNewest.wrappedValue,
                didRequestScrollToTarget: shouldScrollToBottom
            )

            if shouldAutoScroll {
                let count = tableView.numberOfRows
                if count > 0 {
                    if shouldScrollToBottom {
                        // Explicit jump (button/tab switch): animate
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.2
                            context.allowsImplicitAnimation = true
                            tableView.scrollRowToVisible(count - 1)
                        }
                    } else {
                        // Auto-follow: instant, stays in sync with row insert
                        tableView.scrollRowToVisible(count - 1)
                    }
                }
                return
            }

            guard let anchorID,
                  let anchorIndex = rows.firstIndex(where: { $0.id == anchorID }) else {
                    return
            }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard !visibleRows.contains(anchorIndex) else { return }
            tableView.scrollRowToVisible(anchorIndex)
        }

        private func updateIsAtBottom(in tableView: NSTableView) {
            guard !isProgrammaticUpdate else { return }
            let atBottom = isUserAtBottom(in: tableView)
            scheduleScrollStateUpdate(isAtBottom: atBottom)
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            if let menuDidBeginObserver {
                NotificationCenter.default.removeObserver(menuDidBeginObserver)
            }
            if let menuDidEndObserver {
                NotificationCenter.default.removeObserver(menuDidEndObserver)
            }
            rowUpdateScheduler.cancel()
            columnSizingScheduler.cancel()
            scrollStateWorkItem?.cancel()
        }

        private func makeTextField(for identifier: NSUserInterfaceItemIdentifier, row: PacketRowViewModel) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.backgroundColor = .clear
            field.drawsBackground = false

            switch identifier.rawValue {
            case ColumnIdentifier.time.rawValue:
                field.stringValue = row.timeText
                field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                field.textColor = .secondaryLabelColor
                field.alignment = .left
                field.toolTip = row.timeText
            case ColumnIdentifier.from.rawValue:
                field.stringValue = row.fromText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .left
                field.toolTip = row.fromText
            case ColumnIdentifier.to.rawValue:
                field.stringValue = row.toText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .left
                field.toolTip = row.toText
            case ColumnIdentifier.via.rawValue:
                field.stringValue = row.viaText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = .secondaryLabelColor
                field.alignment = .left
                field.lineBreakMode = .byTruncatingMiddle
                field.toolTip = row.viaText
            case ColumnIdentifier.type.rawValue:
                field.stringValue = row.typeLabel
                field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                field.textColor = row.isLowSignal ? .tertiaryLabelColor : .secondaryLabelColor
                field.alignment = .center
                field.toolTip = row.typeTooltip
                field.setAccessibilityLabel(row.typeAccessibilityLabel)
            case ColumnIdentifier.info.rawValue:
                field.stringValue = row.infoText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .tertiaryLabelColor : .secondaryLabelColor
                field.alignment = .left
                field.toolTip = row.infoTooltip
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            default:
                field.stringValue = ""
            }

            return field
        }

        private func makeTypePillCell(for identifier: NSUserInterfaceItemIdentifier, row: PacketRowViewModel) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let pillView = TypePillView(text: row.typeLabel, isLowSignal: row.isLowSignal, accessibilityLabel: row.typeAccessibilityLabel)
            pillView.toolTip = row.typeTooltip
            cell.addSubview(pillView)
            pillView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                pillView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                pillView.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func applyPendingUpdate() {
            guard let tableView else {
                SentryManager.shared.captureMessage("Packet table update failed: missing tableView", level: .warning, extra: nil)
                return
            }
            guard let pendingUpdate else { return }
            guard !isContextMenuTracking else { return }
            self.pendingUpdate = nil

            #if DEBUG
            logger.debug("Packet table update started (rows: \(pendingUpdate.packets.count))")
            #endif

            isProgrammaticUpdate = true
            // Capture scroll state BEFORE row mutation so we know user intent
            let wasAtBottom = isUserAtBottom(in: tableView)
            let visibleAnchorID = firstVisiblePacketID(in: tableView)
            let shouldScrollToBottom = pendingUpdate.scrollToBottomToken != lastScrollToBottomToken
            lastScrollToBottomToken = pendingUpdate.scrollToBottomToken
            let updateAction = updateRows(
                packets: pendingUpdate.packets,
                in: tableView
            )
            applySelection(pendingUpdate.selection)
            updateScrollPosition(
                in: tableView,
                anchorID: visibleAnchorID,
                wasAtBottom: wasAtBottom,
                shouldScrollToBottom: shouldScrollToBottom
            )
            scheduleColumnSizing(for: tableView)
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                self.isProgrammaticUpdate = false
                self.updateIsAtBottom(in: tableView)
            }

            #if DEBUG
            logger.debug("Packet table update finished (\(String(describing: updateAction)))")
            #endif

            SentryManager.shared.addBreadcrumb(
                category: "ui.packets",
                message: "Packet list updated",
                level: .info,
                data: ["rowCount": rows.count]
            )
        }

        private func observeMenuTracking(for menu: NSMenu?) {
            if let menuDidBeginObserver {
                NotificationCenter.default.removeObserver(menuDidBeginObserver)
                self.menuDidBeginObserver = nil
            }
            if let menuDidEndObserver {
                NotificationCenter.default.removeObserver(menuDidEndObserver)
                self.menuDidEndObserver = nil
            }
            guard let menu else { return }
            menuDidBeginObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: menu,
                queue: .main
            ) { [weak self] _ in
                self?.isContextMenuTracking = true
            }
            menuDidEndObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: menu,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isContextMenuTracking = false
                self.applyPendingUpdate()
            }
        }

        private func updateRows(packets: [Packet], in tableView: NSTableView) -> RowUpdate {
            let newIDs = packets.map(\.id)
            let oldIDs = rows.map(\.id)

            if newIDs == oldIDs {
                self.packets = packets
                return .none
            }

            if rows.isEmpty {
                rows = packets.map { PacketRowViewModel.fromPacket($0) }
                self.packets = packets
                tableView.reloadData()
                return .reload
            }

            if newIDs.count >= oldIDs.count {
                let delta = newIDs.count - oldIDs.count
                if delta > 0, Array(newIDs.prefix(oldIDs.count)) == oldIDs {
                    let newRows = packets.suffix(delta).map { PacketRowViewModel.fromPacket($0) }
                    let startRow = rows.count
                    rows.append(contentsOf: newRows)
                    self.packets = packets
                    tableView.beginUpdates()
                    tableView.insertRows(at: IndexSet(integersIn: startRow..<(startRow + delta)), withAnimation: [])
                    tableView.endUpdates()
                    return .insert(count: delta)
                }
            }

            if newIDs.count <= oldIDs.count {
                let delta = oldIDs.count - newIDs.count
                if delta > 0, Array(oldIDs.prefix(newIDs.count)) == newIDs {
                    let start = oldIDs.count - delta
                    rows.removeLast(delta)
                    self.packets = packets
                    tableView.beginUpdates()
                    tableView.removeRows(at: IndexSet(integersIn: start..<oldIDs.count), withAnimation: [])
                    tableView.endUpdates()
                    return .remove(range: start..<oldIDs.count)
                }
            }

            rows = packets.map { PacketRowViewModel.fromPacket($0) }
            self.packets = packets
            tableView.reloadData()
            return .reload
        }

        private func scheduleScrollStateUpdate(isAtBottom: Bool) {
            guard lastPublishedIsAtBottom != isAtBottom else { return }
            lastPublishedIsAtBottom = isAtBottom
            
            DispatchQueue.main.async { [weak self] in
                self?.isAtBottom.wrappedValue = isAtBottom
            }
        }

        private func scheduleColumnSizing(for tableView: NSTableView) {
            columnSizingScheduler.schedule { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                await MainActor.run {
                    PacketNSTableView.sizeColumnsToFitContent(in: tableView, rows: self.rows)
                    PacketNSTableView.expandInfoColumnToFill(in: tableView)
                }
            }
        }

        private func isUserAtBottom(in tableView: NSTableView) -> Bool {
            let numberOfRows = tableView.numberOfRows
            guard numberOfRows > 0 else { return true }
            let visibleRowRange = tableView.rows(in: tableView.visibleRect)
            return visibleRowRange.contains(numberOfRows - 1)
        }
    }
}

private final class TypePillView: NSView {
    private let textField = NSTextField(labelWithString: "")

    init(text: String, isLowSignal: Bool, accessibilityLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true
        textField.stringValue = text
        textField.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        textField.alignment = .center
        textField.textColor = isLowSignal ? .tertiaryLabelColor : .secondaryLabelColor
        setAccessibilityLabel(accessibilityLabel)
        textField.setContentHuggingPriority(.required, for: .horizontal)
        textField.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(textField)
        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = (isLowSignal ? NSColor.quaternaryLabelColor : NSColor.tertiaryLabelColor).cgColor
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

nonisolated private struct PacketTableColumnSizer {
    let rows: [PacketRowViewModel]

    func width(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        let headerWidth = columnHeaderWidth(for: column)
        let contentWidth = columnContentWidth(for: column)
        let maxWidth = columnMaxWidth(for: column)
        return min(max(headerWidth, contentWidth) + 12, maxWidth)
    }

    private func columnHeaderWidth(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        let title: String
        switch column {
        case .time: title = "Time"
        case .from: title = "From"
        case .to: title = "To"
        case .via: title = "Via"
        case .type: title = "Frame Type"
        case .info: title = "Info"
        }
        return title.size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
    }

    private func columnContentWidth(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        let font: NSFont
        let values: [String]
        switch column {
        case .time:
            font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            values = rows.map { $0.timeText }
        case .from:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.fromText }
        case .to:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.toText }
        case .via:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.viaText }
        case .type:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            values = rows.map { $0.typeLabel }
        case .info:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.infoText }
        }
        let measured = values.reduce(CGFloat.zero) { current, value in
            let width = value.size(withAttributes: [.font: font]).width
            return max(current, width)
        }
        return measured
    }

    private func columnMaxWidth(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        switch column {
        case .time: return 140
        case .from, .to: return 200
        case .via: return 420
        case .type: return 80
        case .info: return 1200
        }
    }
}
