import AppKit
import ExchangeMailKit
import Observation
import SwiftUI

enum SearchScope: Hashable {
    case folder, all
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    let auth: GraphAuth
    let signatures: SignatureStore
    let addressBook: AddressBookStore
    /// 새 메일 알림과 Dock 배지 (S-024)
    @ObservationIgnored let notifier: any MailNotifier
    var notificationPermission = NotifyPermission.notAsked
    @ObservationIgnored var tracker = NewMailTracker()
    @ObservationIgnored var trackerLoaded = false
    /// 알림을 눌러 열 메일. 받은 편지함 목록이 오면 고른다.
    @ObservationIgnored var pendingOpenID: String?
    let isDemo: Bool
    @ObservationIgnored let service: any MailService
    /// 본문 웹 보기 넘기기 (S-019)
    @ObservationIgnored let pageScroller = PageScroller()

    // 폴더
    var folders: [MailFolder] = []
    var selectedFolderID: String? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            searchText = ""
            Task { await loadMessages() }
        }
    }

    // 목록
    var messages: [MailMessage] = []
    private(set) var nextLink: String?
    var searchText = ""
    private(set) var isLoading = false
    private(set) var isLoadingMore = false

    /// 목록에서 고른 줄들 (S-027). 한 줄이면 `selectedMessageID`와 같고, 여러 줄이면 본문은 비운다.
    var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            let single = selection.count == 1 ? selection.first : nil
            if selectedMessageID != single { selectedMessageID = single }
            updateMenu()
        }
    }
    /// 메시지 > 이동… 시트 (S-028)
    var showMovePicker = false
    /// 검색 범위 (S-033). 바꾸면 검색어가 있을 때 다시 찾는다.
    var searchScope = SearchScope.folder {
        didSet {
            guard searchScope != oldValue, !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task { await loadMessages() }
        }
    }
    /// 목록 필터 (S-041). 바꾸면 다시 불러온다. 폴더를 옮겨도 해제할 때까지 남는다.
    var listFilter = MailFilter() {
        didSet {
            guard listFilter != oldValue else { return }
            updateMenu()
            Task { await loadMessages(keepSelection: true) }
        }
    }
    /// 정렬 기준 (S-042). 앱을 다시 열어도 남는다. 날짜 방향이 바뀔 때만 서버에서 다시 받는다.
    var listSort = AppModel.savedSort() {
        didSet {
            guard listSort != oldValue else { return }
            if let data = try? JSONEncoder().encode(listSort), !Store.isOverridden {
                UserDefaults.standard.set(data, forKey: "list.sort")
            }
            if listSort.serverOldestFirst != oldValue.serverOldestFirst {
                Task { await loadMessages(keepSelection: true) }
            } else {
                messages = listSort.apply(messages)
            }
            updateMenu()
        }
    }
    /// Outlook 범주 이름 (필터 메뉴)
    var categories: [String] = []
    /// VIP와 스마트 메일상자 (S-045, S-046)
    let mailboxes = MailboxStore(url: Store.directory.appending(path: "mailboxes.json"))
    /// 열린 VIP 편집 시트 (이름·아이콘)
    var editingVIP: VIP?
    /// 열린 스마트 메일상자 편집 시트
    var editingSmart: SmartMailbox?

    static func savedSort() -> MailSort {
        guard !Store.isOverridden, let data = UserDefaults.standard.data(forKey: "list.sort"),
              let sort = try? JSONDecoder().decode(MailSort.self, from: data) else { return MailSort() }
        return sort
    }

    /// Quick Look으로 보는 첨부 파일 (S-032)
    var previewURL: URL?
    /// 인쇄가 끝날 때까지 잡아 둔다 (S-034)
    @ObservationIgnored var printer: MailPrinter?

    // 본문
    var selectedMessageID: String? {
        didSet {
            guard selectedMessageID != oldValue else { return }
            // 목록 선택과 맞춘다: 한 통을 고르면 그 줄만, 비우면(여러 줄이 아닐 때) 선택도 비운다.
            if let id = selectedMessageID {
                if selection != [id] { selection = [id] }
            } else if selection.count == 1 {
                selection = []
            }
            allowRemoteFor = nil
            shownMessageID = nil
            thread = []
            updateMenu()
            Task {
                await loadDetail()
                await loadThread()
            }
        }
    }
    /// 대화 보기에서 펼친 메일 (S-025). nil이면 목록에서 고른 메일.
    private(set) var shownMessageID: String?
    /// 고른 메일의 대화 전체, 오래된 순 (S-025). 대화가 아니면 비어 있다.
    var thread: [MailMessage] = []
    /// 본문에 보이는 메일 id
    var displayedMessageID: String? { shownMessageID ?? selectedMessageID }
    private(set) var detail: MailMessage?
    /// 인라인 첨부까지 모두. 목록에 보일 첨부는 `listedAttachments`.
    private(set) var detailAttachments: [FileAttachment] = []
    /// cid 그림을 data: URI로 바꾼 본문
    private(set) var detailBody: MailMessage.Body?
    /// 원격 이미지를 허용한 메시지 id (다른 메시지로 옮기면 다시 차단)
    private(set) var allowRemoteFor: String?

    var errorMessage: String?
    /// 스냅숏에서 로그인 화면을 찍을 때만 켠다.
    var previewSignIn = false

    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .account {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    init(auth: GraphAuth, signatures: SignatureStore, addressBook: AddressBookStore, service: any MailService,
         notifier: any MailNotifier, isDemo: Bool) {
        self.addressBook = addressBook
        self.notifier = notifier
        self.auth = auth
        self.signatures = signatures
        self.service = service
        self.isDemo = isDemo
    }

    static func make() -> AppModel {
        let signatures = SignatureStore(url: Store.directory.appending(path: "signatures.json"))
        let addressBook = AddressBookStore(url: Store.directory.appending(path: "recipients.json"))
        let auth = GraphAuth(demoEmail: Store.isDemo ? DemoMailService.myAddress : nil)
        let remote: any MailService
        if Store.isDemo {
            if signatures.signatures.isEmpty { DemoMailService.seedSignatures(into: signatures) }
            remote = DemoMailService()
        } else {
            remote = GraphMailService(auth: auth)
        }
        // 오프라인 캐시를 끼운다 (S-026). 데모도 같은 경로를 써서 셀프 테스트가 오프라인을 흉내 낸다.
        let cached = CachedMailService(remote: remote, base: Store.directory.appending(path: "cache", directoryHint: .isDirectory),
                                       account: { auth.email }, enabled: { AppModel.cacheEnabled })
        let model = AppModel(auth: auth, signatures: signatures, addressBook: addressBook, service: cached,
                             notifier: Store.isDemo ? RecordingNotifier() : SystemNotifier.shared, isDemo: Store.isDemo)
        cached.onOfflineChange = { [weak model] offline in model?.isOffline = offline }
        return model
    }

    // MARK: 오프라인 (S-026)

    /// 네트워크가 없어 저장된 메일을 보여 주는 중
    var isOffline = false
    static var cacheEnabled: Bool { UserDefaults.standard.object(forKey: "cache.enabled") as? Bool ?? true }
    var cachedService: CachedMailService? { service as? CachedMailService }
    /// 데모 사서함 (스냅숏, 셀프 테스트)
    var demoService: DemoMailService? { (cachedService?.remote ?? service) as? DemoMailService }

    /// 오프라인 막대의 "다시 연결"
    func retryConnection() async {
        if await cachedService?.retry() == true { await refresh() }
    }

    /// 로그아웃: 이 계정의 저장된 메일을 지운 뒤 나간다.
    func signOut() {
        cachedService?.clearCache()
        auth.signOut()
    }

    var isSignedIn: Bool { auth.isSignedIn }
    var showsMail: Bool { isSignedIn && !previewSignIn }

    var selectedFolder: MailFolder? { folders.first { $0.id == selectedFolderID } }
    var selectedMessage: MailMessage? { messages.first { $0.id == selectedMessageID } }
    var listedAttachments: [FileAttachment] { detailAttachments.filter(\.isListed) }

    var detailHasRemoteContent: Bool { detailBody.map { $0.isHTML && MailContent.hasRemoteContent($0.content) } ?? false }
    var remoteContentAllowed: Bool { detail != nil && allowRemoteFor == detail?.id }

    // MARK: 불러오기

    /// 폴더와 목록을 처음부터 불러온다 (로그인 직후).
    func reloadAll() async {
        guard isSignedIn else {
            folders = []; messages = []; detail = nil
            // 로그아웃: 배지를 지우고, 다음 계정은 새 기준으로 시작한다.
            tracker = NewMailTracker()
            trackerLoaded = false
            updateBadge()
            updateMenu()
            return
        }
        await loadFolders()
        categories = (try? await service.categories()) ?? []
        if selectedFolderID == nil || !folders.contains(where: { $0.id == selectedFolderID }) {
            // didSet이 목록을 불러온다.
            selectedFolderID = folders.first { $0.kind == "inbox" }?.id ?? folders.first?.id
        } else {
            await loadMessages()
        }
        updateMenu()
    }

    /// 받은 메일 가져오기: 선택한 폴더와 메일을 유지한 채 다시 불러온다.
    func refresh() async {
        guard isSignedIn else { return }
        await loadFolders()
        await loadMessages(keepSelection: true)
    }

    func loadFolders() async {
        // 처음에는 저장된 폴더를 먼저 보여 준다 (S-026).
        if folders.isEmpty, let saved = cachedService?.cache?.folders() { folders = FolderOrder.tree(saved) }
        do {
            folders = FolderOrder.tree(try await service.folders())
            updateBadge()
        } catch {
            report(error)
        }
    }

    func loadMessages(keepSelection: Bool = false) async {
        guard let folderID = selectedFolderID else { return }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        // 비어 있으면 저장된 목록을 먼저 보여 주고 서버 응답으로 바꾼다 (S-026).
        if messages.isEmpty, search.isEmpty, let saved = cachedService?.cache?.list(folderID: folderID) {
            messages = saved.messages
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page: MessagePage
            if !search.isEmpty && (searchScope == .all || VirtualMailbox.isVirtual(folderID)) {
                // 모든 폴더 검색 (S-033). 깃발 표시·VIP·스마트 메일상자는 서버 폴더가 아니라서 그 안의 검색도 전체 검색이다.
                page = try await service.searchAll(search)
            } else if let box = VirtualMailbox(id: folderID) {
                page = try await loadVirtual(box)
            } else {
                page = try await service.messages(folderID: folderID, search: search.isEmpty ? nil : search,
                                                  filter: listFilter.isActive ? listFilter : nil,
                                                  oldestFirst: listSort.serverOldestFirst)
            }
            // 기다리는 사이 폴더나 검색어가 바뀌었으면 버린다.
            guard folderID == selectedFolderID, search == searchText.trimmingCharacters(in: .whitespaces) else { return }
            // 서버 폴더가 아닌 상자·모든 폴더 검색은 서버 필터를 쓰지 않으므로 앱이 다 건다.
            let serverFiltered = page.serverFiltered && !VirtualMailbox.isVirtual(folderID) && search.isEmpty
            messages = arrange(page.messages, serverFiltered: serverFiltered)
            addressBook.noteSeen(page.messages, me: auth.email)
            nextLink = page.nextLink
            if let pending = pendingOpenID, messages.contains(where: { $0.id == pending }) {
                pendingOpenID = nil
                selectedMessageID = pending
            } else if !(keepSelection && messages.contains { $0.id == selectedMessageID }) {
                selectedMessageID = nil
            }
        } catch {
            report(error)
        }
    }

    /// 목록 끝에 닿으면 다음 쪽을 더 불러온다.
    func loadMore() async {
        guard let link = nextLink, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.nextPage(link)
            guard link == nextLink else { return }
            let known = Set(messages.map(\.id))
            let more = arrange(page.messages, serverFiltered: page.serverFiltered).filter { !known.contains($0.id) }
            messages = listSort.apply(messages + more)
            nextLink = page.nextLink
        } catch {
            report(error)
        }
    }

    func loadDetail() async {
        guard let id = displayedMessageID else {
            detail = nil; detailBody = nil; detailAttachments = []
            updateMenu()
            return
        }
        do {
            let m = try await service.message(id: id)
            var attachments: [FileAttachment] = []
            if (m.hasAttachments ?? false) || (m.body?.content.contains("cid:") ?? false) {
                attachments = try await service.attachments(messageID: id)
            }
            guard id == displayedMessageID else { return }
            detail = m
            addressBook.noteSeen([m], me: auth.email)
            detailAttachments = attachments
            detailBody = MailContent.displayBody(m.body, attachments: attachments)
            updateMenu()
            if m.isUnread { await setRead(id: id, true) }
        } catch {
            report(error)
        }
    }

    /// 필터의 앱 쪽 부분을 걸고 정렬한다 (S-041, S-042).
    func arrange(_ list: [MailMessage], serverFiltered: Bool) -> [MailMessage] {
        let me = auth.email.map { MailAddress(name: auth.displayName, address: $0) }
        let kept = listFilter.isActive ? list.filter { listFilter.matches($0, me: me, serverFiltered: serverFiltered) } : list
        return listSort.apply(kept)
    }

    // MARK: 바꾸기

    func setRead(id: String, _ read: Bool) async {
        do {
            try await service.setRead(id: id, read: read)
            if let i = messages.firstIndex(where: { $0.id == id }), messages[i].isRead != read {
                messages[i].isRead = read
                if let f = folders.firstIndex(where: { $0.id == selectedFolderID }) {
                    folders[f].unreadItemCount = max(0, (folders[f].unreadItemCount ?? 0) + (read ? -1 : 1))
                }
            }
            if detail?.id == id { detail?.isRead = read }
            if let t = thread.firstIndex(where: { $0.id == id }) { thread[t].isRead = read }
            updateBadge()
            updateMenu()
        } catch {
            report(error)
        }
    }

    /// 목록에서 위아래 메일로 옮긴다. 끝에서는 그대로 있는다. 옮겼으면 true.
    @discardableResult
    func selectAdjacent(_ offset: Int) -> Bool {
        let order = navigationOrder
        guard !order.isEmpty else { return false }
        let current = order.firstIndex { $0 == selectedMessageID }
        let target = current.map { $0 + offset } ?? (offset > 0 ? 0 : order.count - 1)
        guard order.indices.contains(target) else { return false }
        selectedMessageID = order[target]
        return true
    }

    /// Space: 본문을 한 쪽 내리고, 끝이었으면 다음 메일. ⇧Space: 한 쪽 올리고, 처음이었으면 이전 메일 (맥 Mail과 같다).
    func pageOrAdvance(down: Bool) async {
        guard detail != nil else {
            selectAdjacent(down ? 1 : -1)
            return
        }
        if await pageScroller.page(down: down) {
            selectAdjacent(down ? 1 : -1)
        }
    }

    /// 고른 메일을 모두 읽음(하나라도 안 읽었으면) 또는 모두 안 읽음으로 (S-027).
    func toggleReadSelected() async {
        let targets = messages.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let makeRead = targets.contains(where: \.isUnread)
        for m in targets where m.isUnread == makeRead { await setRead(id: m.id, makeRead) }
    }

    /// 보관도 지우기처럼 ⌘Z로 되돌린다 (창의 되돌리기 관리자를 넘긴다).
    func archiveSelected(undoManager: UndoManager? = nil) async {
        await moveSelected(to: "archive", undoManager: undoManager, undoName: "보관")
    }

    func deleteSelected(undoManager: UndoManager?) async {
        await moveSelected(to: "deleteditems", undoManager: undoManager, undoName: "지우기")
    }

    /// 고른 메일(여러 통, 대화별이면 대화 전체)을 옮긴다 (S-027).
    func moveSelected(to destination: String, undoManager: UndoManager?, undoName: String) async {
        await move(selectedIDs, to: destination, undoManager: undoManager, undoName: undoName)
    }

    /// 메일을 옮기고 다음 줄을 고른다. ⌘Z는 메일마다 원래 폴더로 되돌린다 (S-028).
    func move(_ ids: [String], to destination: String, undoManager: UndoManager?, undoName: String) async {
        let targets = messages.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let order = navigationOrder
        let position = order.firstIndex { ids.contains($0) } ?? 0
        var moves: [UndoMove] = []
        do {
            for m in targets {
                // 깃발 모아 보기처럼 여러 폴더가 섞인 목록에서도 원래 폴더로 돌아가게 메일의 폴더를 기억한다.
                let from = m.parentFolderId ?? selectedFolderID ?? "inbox"
                let newID = try await service.move(id: m.id, to: destination)
                moves.append(UndoMove(messageID: newID, folderID: from))
            }
        } catch {
            // 사람이 누른 동작이라 오프라인이어도 알린다.
            report(error, quietIfOffline: false)
        }
        guard !moves.isEmpty else { return }
        let movedOld = Set(targets.prefix(moves.count).map(\.id))
        messages.removeAll { movedOld.contains($0.id) }
        selection = []
        let remaining = navigationOrder
        selectedMessageID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)]
        let undoMoves = moves
        undoManager?.registerUndo(withTarget: self) { target in
            // 되돌리기는 메인 스레드에서 불린다.
            MainActor.assumeIsolated {
                _ = Task { await target.restore(undoMoves) }
            }
        }
        undoManager?.setActionName(undoName)
        await loadFolders()
    }

    struct UndoMove: Sendable {
        var messageID: String
        var folderID: String
    }

    func restore(_ moves: [UndoMove]) async {
        do {
            for m in moves { _ = try await service.move(id: m.messageID, to: m.folderID) }
            await refresh()
        } catch {
            report(error, quietIfOffline: false)
        }
    }

    /// 대화 안의 다른 메일을 펼친다 (S-025). 목록 선택은 그대로 두고 본문만 바꾼다.
    func showInThread(_ id: String) {
        guard id != displayedMessageID else { return }
        shownMessageID = id == selectedMessageID ? nil : id
        allowRemoteFor = nil
        Task { await loadDetail() }
    }

    /// 회의 초대에 답한다 (S-038). Exchange는 응답을 비동기로 처리하므로, 보낸 뒤 일정을 다시 읽어
    /// 서버가 실제로 기록한 상태를 막대에 보인다. 몇 초 안에 반영되지 않으면 서버 상태와 함께 알린다.
    func respondToMeeting(_ response: MeetingResponse) async {
        guard let eventID = detail?.event?.id else { return }
        do {
            try await service.respond(toEvent: eventID, with: response)
        } catch {
            report(error, quietIfOffline: false)
            return
        }
        var serverValue: String?
        for wait in [1.0, 2.0, 3.0] {
            try? await Task.sleep(for: .seconds(wait))
            do {
                let fresh = try await service.event(id: eventID)
                serverValue = fresh.responseStatus?.response
                if detail?.event?.id == eventID { detail?.event = fresh }
                if serverValue == response.graphValue { return }
            } catch {
                errorMessage = "회의 응답은 보냈지만 일정을 다시 찾을 수 없습니다. 주최자가 일정을 바꿨거나 취소했을 수 있습니다. "
                    + "Outlook 웹에서 확인해 주세요.\n(\(error.localizedDescription))"
                return
            }
        }
        errorMessage = "회의 응답(\(response.label))을 보냈지만 Exchange 일정에 아직 반영되지 않았습니다. "
            + "지금 서버 상태: \(MeetingResponse.describe(serverValue)). 잠시 뒤 Outlook 일정에서 다시 확인해 주세요."
    }

    /// 본문에 보이는 메일이 `id`이면 고친다 (다른 파일의 확장이 `detail`을 바꿀 때).
    func patchDetail(_ id: String, _ change: (inout MailMessage) -> Void) {
        guard var m = detail, m.id == id else { return }
        change(&m)
        detail = m
    }

    func allowRemoteContentForSelection() {
        allowRemoteFor = detail?.id
        updateMenu()
    }

    // MARK: helpers

    /// 오류를 알린다. 오프라인이면 막대가 이미 말해 주므로, 자동으로 일어난 일은 조용히 넘긴다 (S-026).
    func report(_ error: Error, quietIfOffline: Bool = true) {
        if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
        if OfflineError.isOffline(error) {
            isOffline = true
            if quietIfOffline { return }
            errorMessage = (error as? OfflineError)?.localizedDescription ?? OfflineError.unavailable("이 작업을 할").localizedDescription
            return
        }
        errorMessage = error.localizedDescription
    }

    func updateMenu() {
        MenuState.shared.update(MenuSnapshot(
            signedIn: isSignedIn,
            hasMessage: detail != nil && selectedMessageID != nil,
            hasSelection: !selectedIDs.isEmpty,
            isUnread: messages.filter { selectedIDs.contains($0.id) }.contains(where: \.isUnread),
            isFlagged: !messages.filter { selectedIDs.contains($0.id) }.contains { !$0.isFlagged },
            inJunk: selectedFolder?.kind == "junkemail",
            hasAttachments: !listedAttachments.isEmpty,
            canPrint: detail != nil && multipleSelectionCount == 0,
            sortKey: listSort.key,
            sortDescending: listSort.descending,
            filterActive: listFilter.isActive,
            isDraft: isDraftSelected,
            hasRemoteContent: detailHasRemoteContent && !remoteContentAllowed,
            senderIsVIP: detail.flatMap { mailboxes.vip(for: $0) } != nil))
    }
}
