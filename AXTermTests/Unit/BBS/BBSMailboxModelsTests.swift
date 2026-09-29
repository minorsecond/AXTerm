import XCTest
@testable import AXTerm

/// The decisions the mailbox UI makes, pinned away from the views.
///
/// These are the rules the Mac panes and the iOS screens share. Sealing any of
/// them inside a view would mean two platforms each deciding separately what
/// counts as the sysop's mail — and only one of the two ever being looked at.
final class BBSMailboxModelsTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(id: Int64,
                         from: String = "W0ARP",
                         to: String,
                         subject: String = "hello",
                         offset: TimeInterval = 0,
                         read: Bool = false,
                         killed: Bool = false) -> BBSMessage {
        BBSMessage(id: id,
                   from: from,
                   to: to,
                   subject: subject,
                   body: "body",
                   receivedAt: epoch.addingTimeInterval(offset),
                   readAt: read ? epoch : nil,
                   killedAt: killed ? epoch : nil)
    }

    // MARK: - Presentation and navigation

    func testOnlyTheTabPlacementBringsItsOwnNavigation() {
        XCTAssertTrue(BBSScreenPresentation.tab.ownsNavigation,
                      "a tab's content has no navigation around it, so the mailbox "
                      + "supplies the split view")
        XCTAssertFalse(BBSScreenPresentation.pushed.ownsNavigation,
                       "pushed inside the shell's stack, a stack of its own would double "
                       + "the back button and a split view would collapse to one squeezed "
                       + "column with two navigation bars")
    }

    func testThePaneRowsAreTheFourPanesInOrder() {
        let rows = BBSPaneList.rows(messageBadge: 0, liveCallers: 0)
        XCTAssertEqual(rows.map(\.pane), BBSPane.allCases,
                       "the mailbox's own navigation is the same four panes on both "
                       + "platforms, in the same order")
        XCTAssertEqual(rows.compactMap(\.badge), [],
                       "zero is not a number worth printing beside a name")
    }

    func testOnlyCountsThatMoveOnTheirOwnAreBadged() {
        let rows = BBSPaneList.rows(messageBadge: 4, liveCallers: 1)
        XCTAssertEqual(rows.first { $0.pane == .messages }?.badge, 4)
        XCTAssertEqual(rows.first { $0.pane == .callers }?.badge, 1)
        XCTAssertNil(rows.first { $0.pane == .directory }?.badge,
                     "the directory holds what the operator put there; a badge that never "
                     + "moves teaches them to stop reading badges")
        XCTAssertNil(rows.first { $0.pane == .files }?.badge)
    }

    // MARK: - Which messages a filter shows

    func testMineIsMailAddressedToTheSysopWhateverSSIDTheyAnswerOn() {
        let messages = [
            message(id: 1, to: "K0EPI"),
            message(id: 2, to: "K0EPI-7"),
            message(id: 3, to: "W0ARP")
        ]
        let mine = BBSMessageList.visible(messages, filter: .mine, sysop: "K0EPI-2")
        XCTAssertEqual(mine.map(\.id).sorted(), [1, 2],
                       "mail is addressed to an operator, not to a radio: base "
                       + "callsigns match and SSIDs do not enter into it")
    }

    func testMineExcludesBulletins() {
        let messages = [
            message(id: 1, to: BBSMessage.allCall),
            message(id: 2, to: "K0EPI")
        ]
        XCTAssertEqual(BBSMessageList.visible(messages, filter: .mine, sysop: "K0EPI").map(\.id),
                       [2],
                       "a notice to everybody is not mail for anybody")
    }

    func testBulletinsAreEveryMessageAddressedToALL() {
        let messages = [
            message(id: 1, to: "ALL"),
            message(id: 2, to: "all-1"),
            message(id: 3, to: "K0EPI")
        ]
        XCTAssertEqual(BBSMessageList.visible(messages, filter: .bulletins, sysop: "K0EPI")
                        .map(\.id).sorted(),
                       [1, 2],
                       "a bulletin is a message addressed to ALL — there is no separate kind")
    }

    func testEveryFilterButKilledHidesKilledMessages() {
        let messages = [
            message(id: 1, to: "K0EPI", killed: true),
            message(id: 2, to: "ALL", killed: true),
            message(id: 3, to: "K0EPI")
        ]
        for filter in [BBSMessageFilter.mine, .bulletins, .all] {
            XCTAssertFalse(BBSMessageList.visible(messages, filter: filter, sysop: "K0EPI")
                            .contains { $0.killedAt != nil },
                           "\(filter.label) must agree with what a caller can see")
        }
        XCTAssertEqual(BBSMessageList.visible(messages, filter: .killed, sysop: "K0EPI")
                        .map(\.id).sorted(),
                       [1, 2],
                       "Killed is the only place a killed message shows, so a mistaken K "
                       + "can be undone")
    }

    func testListingIsNewestFirst() {
        let messages = [
            message(id: 1, to: "K0EPI", offset: 0),
            message(id: 2, to: "K0EPI", offset: 600),
            message(id: 3, to: "K0EPI", offset: 300)
        ]
        XCTAssertEqual(BBSMessageList.visible(messages, filter: .mine, sysop: "K0EPI").map(\.id),
                       [2, 3, 1],
                       "the newest thing a caller left is the thing the operator wants first")
    }

    // MARK: - Unread

    func testABulletinIsNeverUnread() {
        let bulletin = message(id: 1, to: BBSMessage.allCall)
        XCTAssertFalse(BBSMessageList.isUnread(bulletin, sysop: "K0EPI"),
                       "a bulletin has many readers and one flag cannot describe them, "
                       + "so an unread bulletin would badge the mailbox forever")
        XCTAssertFalse(BBSMessageList.shouldMarkRead(bulletin, sysop: "K0EPI"),
                       "opening a bulletin in the app must not stamp readAt")
    }

    func testOnlyTheSysopsOwnUnreadMailCounts() {
        let messages = [
            message(id: 1, to: "K0EPI"),
            message(id: 2, to: "K0EPI", read: true),
            message(id: 3, to: "W0ARP"),
            message(id: 4, to: "K0EPI", killed: true)
        ]
        XCTAssertEqual(BBSMessageList.unreadCount(messages, sysop: "K0EPI-2"), 1,
                       "read mail, somebody else's mail and killed mail are not unread mail")
    }

    func testAnEmptySubjectSaysSoRatherThanDrawingNothing() {
        XCTAssertEqual(BBSMessageList.subjectLabel(message(id: 1, to: "K0EPI", subject: "   ")),
                       "(no subject)",
                       "a blank row reads as a rendering fault rather than as a real message")
    }

    func testEveryFilterExplainsItsOwnEmptyState() {
        XCTAssertTrue(BBSMessageFilter.mine.emptyDetail(sysop: "K0EPI-2").contains("S K0EPI-2"),
                      "the empty state names the command that would fill it, with the "
                      + "address the mailbox actually answers on")
        for filter in BBSMessageFilter.allCases {
            XCTAssertFalse(filter.emptyTitle.isEmpty)
            XCTAssertFalse(filter.emptyDetail(sysop: "K0EPI").isEmpty,
                           "\(filter.label) must say what would put something here")
        }
    }

    // MARK: - Other mailboxes

    private var remoteOrigin: BBSUnifiedListing.Origin {
        .otherMailbox(BBSUnifiedListing.RemoteOrigin(
            mailbox: "K0EPI-9", station: "K0EPI-1", deviceID: "ipad",
            deviceName: "iPad", gridSquare: "DM79"))
    }

    func testTheChipAppearsOnlyWithSomewhereToReadFromAndSomethingToShow() {
        XCTAssertFalse(BBSRemoteMailbox.showsToggle(hasStore: false, remoteCount: 9, isOn: true),
                       "no store is no unified view, whatever the stored preference says")
        XCTAssertFalse(BBSRemoteMailbox.showsToggle(hasStore: true, remoteCount: 0, isOn: false),
                       "a control for data that has never arrived is a promise the screen "
                       + "cannot keep")
        XCTAssertTrue(BBSRemoteMailbox.showsToggle(hasStore: true, remoteCount: 1, isOn: false))
        XCTAssertTrue(BBSRemoteMailbox.showsToggle(hasStore: true, remoteCount: 0, isOn: true),
                      "switched on with nothing to show, the chip must stay so it can be "
                      + "switched off again")
    }

    func testRemoteRowsAreReadWheneverThereIsAStore() {
        XCTAssertTrue(BBSRemoteMailbox.shouldLoadRemote(hasStore: true),
                      "reading only while the chip is on could never discover there was "
                      + "anything to show, because the chip appears only once something has")
        XCTAssertFalse(BBSRemoteMailbox.shouldLoadRemote(hasStore: false))
    }

    func testAMessageFromAnotherMailboxOffersNothingThatChangesAnything() {
        let actions = BBSMessageActions.forRow(
            message: message(id: 12, to: "K0EPI"), origin: remoteOrigin, sysop: "K0EPI")
        XCTAssertFalse(actions.canKill,
                       "a kill is that mailbox\u{2019}s append-only history, not this one\u{2019}s")
        XCTAssertFalse(actions.marksRead,
                       "reading it here says nothing about whether the operator read it there")
        XCTAssertTrue(actions.isReadOnly)
        XCTAssertFalse(actions.showsUnread,
                       "an unread dot this device can never clear is a badge that teaches "
                       + "the operator to stop reading badges")
        XCTAssertTrue(actions.canReply,
                      "the reply is composed in this mailbox, addressed to whoever wrote it "
                      + "— it writes nothing to the mailbox that took the original")
    }

    func testAKilledMessageFromAnotherMailboxCannotBeRestoredHereEither() {
        let killed = message(id: 12, to: "K0EPI", killed: true)
        XCTAssertFalse(BBSMessageActions.forRow(message: killed, origin: remoteOrigin,
                                                sysop: "K0EPI").canRestore,
                       "restoring it here would invent a state the mailbox that killed it "
                       + "knows nothing about")
        XCTAssertTrue(BBSMessageActions.forRow(message: killed, origin: .thisMailbox,
                                               sysop: "K0EPI").canRestore,
                      "this mailbox\u{2019}s own kill stays undoable")
    }

    func testThisMailboxKeepsEveryActionItHadBefore() {
        let mine = message(id: 3, to: "K0EPI")
        let actions = BBSMessageActions.forRow(message: mine, origin: .thisMailbox,
                                               sysop: "K0EPI-2")
        XCTAssertTrue(actions.canKill)
        XCTAssertFalse(actions.canRestore)
        XCTAssertTrue(actions.marksRead,
                      "reading your own mail in the app is the same fact as reading it "
                      + "over the air")
        XCTAssertTrue(actions.showsUnread, "unread mail for this operator, on this mailbox")
        XCTAssertFalse(actions.isReadOnly)
    }

    func testAMessageWithNoSenderCannotBeRepliedTo() {
        XCTAssertFalse(BBSMessageActions.forRow(message: message(id: 1, from: "  ", to: "ALL"),
                                                origin: .thisMailbox, sysop: "K0EPI").canReply,
                       "there is nowhere to send it")
    }

    func testTheRemoteBannerNamesTheMailboxAndSaysItIsReadOnly() {
        let banner = BBSRemoteMailbox.banner(for: remoteOrigin)
        XCTAssertEqual(banner,
                       "From K0EPI-9\u{2019}s mailbox on iPad. Recorded by that mailbox; "
                       + "read-only here.",
                       "the operator has to be able to tell, from the message they are "
                       + "reading, which station actually took it")
        XCTAssertNil(BBSRemoteMailbox.banner(for: .thisMailbox),
                     "this mailbox\u{2019}s own mail needs no explaining")
    }

    // MARK: - Durations

    func testElapsedIsMinutesAndPaddedSeconds() {
        XCTAssertEqual(BBSElapsed.format(0), "0:00")
        XCTAssertEqual(BBSElapsed.format(7), "0:07")
        XCTAssertEqual(BBSElapsed.format(130), "2:10")
        XCTAssertEqual(BBSElapsed.format(3_600), "60:00",
                       "an hour-long call reads as 60:00 rather than rolling over to 0:00")
    }

    func testAClockSkewedBackwardsShowsZeroRatherThanANegativeCall() {
        XCTAssertEqual(BBSElapsed.format(-42), "0:00",
                       "a call cannot have lasted minus a minute, and the log must not say so")
    }

    // MARK: - Callers

    private func call(id: Int64 = 1,
                      callsign: String = "W0ARP",
                      duration: TimeInterval? = 130,
                      actions: [String] = [],
                      unexpected: Bool = false) -> BBSCall {
        BBSCall(id: id,
                callsign: callsign,
                connectedAt: epoch,
                disconnectedAt: duration.map { epoch.addingTimeInterval($0) },
                actions: actions,
                endedUnexpectedly: unexpected)
    }

    func testACallerWhoLeftNothingIsStillDescribed() {
        let row = BBSCallRowModel.make(call(), now: epoch)
        XCTAssertEqual(row.summary, ["looked around, left nothing"],
                       "a caller who read a bulletin and left nothing is invisible in the "
                       + "message list and must be visible here")
        XCTAssertTrue(row.didNothing)
        XCTAssertEqual(row.duration, "2:10")
    }

    func testALiveCallCountsUpFromNow() {
        let row = BBSCallRowModel.make(call(duration: nil),
                                       now: epoch.addingTimeInterval(65))
        XCTAssertTrue(row.isLive)
        XCTAssertEqual(row.duration, "1:05",
                       "a call still running is timed against now, not against nothing")
        XCTAssertEqual(row.summary, ["connected"],
                       "a live caller who has not done anything yet has not finished either")
    }

    func testActionsAreShownInTheOrderTheyHappened() {
        let row = BBSCallRowModel.make(
            call(actions: ["read 7", "left mail for K0EPI"]), now: epoch)
        XCTAssertEqual(row.summary, ["read 7", "left mail for K0EPI"])
        XCTAssertFalse(row.didNothing)
    }

    func testADroppedLinkIsMarkedOnlyOnceTheCallIsOver() {
        XCTAssertTrue(BBSCallRowModel.make(call(unexpected: true), now: epoch).showsLinkDropped,
                      "a caller who said B got what they came for and one whose link "
                      + "dropped may not have")
        XCTAssertFalse(
            BBSCallRowModel.make(call(duration: nil, unexpected: true), now: epoch)
                .showsLinkDropped,
            "a call still in progress has not dropped, whatever the stale flag says")
    }

    // MARK: - Files

    private func file(name: String = "roster.txt",
                      bytes: Int = 143 * 1024,
                      about: String = "") -> BBSSharedFile {
        BBSSharedFile(area: "OPS", name: name, byteCount: bytes,
                      modifiedAt: epoch, about: about)
    }

    func testAFileRowCarriesTheSameSizeAndAirtimeTheShellQuotes() {
        let row = BBSFileRowModel.make(file(), bytesPerSecond: 90)
        XCTAssertEqual(row.size, BBSFileIndex.size(143 * 1024))
        XCTAssertEqual(row.airtime, BBSFileIndex.duration(bytes: 143 * 1024,
                                                          bytesPerSecond: 90),
                       "the operator's catalogue and the caller's listing must not disagree")
        XCTAssertTrue(row.isText, "a .txt is typed out rather than transferred")
    }

    func testALongTransferIsFlaggedAndAShortOneIsNot() {
        XCTAssertFalse(BBSFileRowModel.make(file(bytes: 4 * 1024), bytesPerSecond: 90)
                        .isLongTransfer)
        XCTAssertTrue(BBSFileRowModel.make(file(bytes: 500 * 1024), bytesPerSecond: 90)
                        .isLongTransfer,
                      "half a megabyte at 90 B/s is an hour and a half of somebody "
                      + "else's channel")
    }

    func testWithNoThroughputFigureNothingIsClaimedAboutAirtime() {
        let row = BBSFileRowModel.make(file(bytes: 5_000_000), bytesPerSecond: 0)
        XCTAssertEqual(row.airtime, "?")
        XCTAssertFalse(row.isLongTransfer,
                       "a division by zero is not evidence that a transfer is long")
    }

    func testAnAreaRowCountsItsFilesAndTheirTotal() {
        let area = BBSFileArea(name: "OPS", about: "Nets")
        let row = BBSAreaRowModel.make(area, files: [file(bytes: 1_024),
                                                     file(name: "b.txt", bytes: 1_024)])
        XCTAssertEqual(row.subtitle, "2 files · 2K")
        XCTAssertEqual(BBSAreaRowModel.make(area, files: [file(bytes: 1_024)]).subtitle,
                       "1 file · 1K",
                       "one file is not \"1 files\"")
        XCTAssertEqual(BBSAreaRowModel.make(area, files: []).subtitle, "0 files · 0B")
    }

    // MARK: - Upload limit

    func testTheUploadSizePickerAlwaysContainsTheStoredValue() {
        XCTAssertEqual(BBSUploadSizeOption.options(including: 100 * 1024).count,
                       BBSUploadSizeOption.standard.count,
                       "a value already on the list does not appear twice")

        let odd = BBSUploadSizeOption.options(including: 250 * 1024)
        XCTAssertTrue(odd.contains { $0.bytes == 250 * 1024 },
                      "a Picker whose selection matches no tag draws blank, and the operator "
                      + "who touches it silently changes a limit they never set")
        XCTAssertEqual(odd.map(\.bytes), odd.map(\.bytes).sorted(),
                       "the list stays in size order wherever the stored value lands")
    }

    func testAnUnsetUploadLimitDoesNotInventAnOption() {
        XCTAssertEqual(BBSUploadSizeOption.options(including: 0).map(\.bytes),
                       BBSUploadSizeOption.standard.map(\.bytes))
    }

    // MARK: - Upload inbox

    func testTheInboxLineStatesTheQuotaAlongsideTheUsage() {
        let box = BBSUploadInboxModel.make(count: 3, bytes: 512 * 1024,
                                           quotaBytes: 20 * 1024 * 1024)
        XCTAssertEqual(box.label, "3 files · 512K of 20M",
                       "the bound is invisible until it bites, so it is stated with the "
                       + "usage rather than reported as a refusal afterwards")
        XCTAssertFalse(box.isFull)
    }

    func testAFullInboxSaysSoBeforeAnUploadIsRefused() {
        let box = BBSUploadInboxModel.make(count: 1, bytes: 20 * 1024 * 1024,
                                           quotaBytes: 20 * 1024 * 1024)
        XCTAssertTrue(box.isFull,
                      "an operator whose uploads start failing cannot tell a full inbox "
                      + "from a broken transfer unless the app says which")
    }

    func testWithNoQuotaNothingIsClaimedAboutBeingFull() {
        let box = BBSUploadInboxModel.make(count: 1, bytes: 100, quotaBytes: 0)
        XCTAssertEqual(box.label, "1 file · 100B",
                       "\"of 0B\" would read as permanently full when nothing is capping it")
        XCTAssertFalse(box.isFull)
    }

    // MARK: - Directory

    func testProvenanceNamesTheCommandOnlyForSomethingSomebodyTyped() {
        let told = WhitePagesEntry.Field(value: "Denver, CO", source: .selfReported,
                                         updatedAt: epoch)
        XCTAssertTrue(BBSDirectoryProvenance.caption(key: .qth, field: told).contains("with NQ"),
                      "the command is what the operator would tell a caller to use")
        XCTAssertTrue(BBSDirectoryProvenance.caption(key: .qth, field: told)
                        .contains(WhitePagesEntry.Source.selfReported.explanation))

        let looked = WhitePagesEntry.Field(value: "Denver, CO", source: .licenceRecord,
                                           updatedAt: epoch)
        XCTAssertFalse(BBSDirectoryProvenance.caption(key: .qth, field: looked).contains("NQ"),
                       "\"set by NQ\" beside a licence lookup names a command nobody ran")
    }

    func testOnlyTestimonyGetsTheQuoteGlyph() {
        XCTAssertEqual(BBSDirectoryProvenance.systemImage(for: .selfReported), "quote.bubble")
        for source in WhitePagesEntry.Source.allCases where source != .selfReported {
            XCTAssertEqual(BBSDirectoryProvenance.systemImage(for: source), "wand.and.stars",
                           "\(source.rawValue) was worked out, not told")
        }
    }

    func testADirectoryRowWithNoNameSaysSoRatherThanDrawingBlank() {
        let row = BBSDirectoryRowModel.make(WhitePagesEntry(callsign: "w0arp"))
        XCTAssertEqual(row.callsign, "W0ARP")
        XCTAssertEqual(row.subtitle, "no name on file")
        XCTAssertFalse(row.hasName)
    }

    func testSuggestionsGroupPerCallsignInTheOrderTheyWereRead() {
        let candidates = [
            BBSDirectoryHarvester.Candidate(callsign: "W0ARP", key: .homeBBS,
                                            value: "K0EPI", evidence: "W0ARP @ K0EPI"),
            BBSDirectoryHarvester.Candidate(callsign: "N0ABC", key: .name,
                                            value: "Ann", evidence: "Name: Ann"),
            BBSDirectoryHarvester.Candidate(callsign: "W0ARP", key: .qth,
                                            value: "Denver", evidence: "QTH: Denver")
        ]
        let groups = BBSDirectorySuggestions.grouped(candidates)
        XCTAssertEqual(groups.map(\.callsign), ["W0ARP", "N0ABC"],
                       "first-seen order is the order of the listing the operator just read")
        XCTAssertEqual(groups.first?.candidates.count, 2,
                       "everything claimed about one person is judged together")
        XCTAssertEqual(BBSDirectorySuggestions.headline(candidates),
                       "3 spotted in BBS sessions")
    }

    // MARK: - Greeting preview

    func testThePreviewIsBuiltByTheShellThatTransmitsIt() {
        let banner = "Open evenings, K0EPI"
        let lines = BBSGreetingPreview.lines(sysop: "K0EPI-2", banner: banner, now: epoch)

        var shell = BBSShell(caller: BBSGreetingPreview.previewCaller,
                             sysop: "K0EPI-2",
                             banner: banner)
        let transmitted = shell.greeting(mailbox: BBSShell.Mailbox(), now: epoch).lines

        XCTAssertEqual(Array(lines.dropLast()), transmitted,
                       "the preview cannot be allowed to drift from what goes on the air")
        XCTAssertEqual(lines.last, BBSShell.commandPrompt,
                       "the prompt is part of what a caller sees on connect")
        XCTAssertTrue(lines.contains(banner),
                      "the banner is the only place this station says when it is around")
    }

    func testAnEmptyBannerPreviewsAsTheHeaderAlone() {
        let lines = BBSGreetingPreview.lines(sysop: "K0EPI", banner: "  \n ", now: epoch)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines[0].contains("K0EPI"),
                      "the header names the mailbox even with nothing else to say")
    }
}
