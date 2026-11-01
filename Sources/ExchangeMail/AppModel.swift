import AppKit
import ExchangeMailKit
import Observation
import SwiftUI

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    let auth: GraphAuth
    let signatures: SignatureStore
    let addressBook: AddressBookStore
    /// 새 메일 알림과 Dock 배지 (S-024)
    @ObservationIgnored let notifier: any MailNotifier
    private(set) var notificationPermission = NotifyPermission.notAsked
    @ObservationIgnored private var tracker = NewMailTracker()
    @ObservationIgnored private var trackerLoaded = false
    /// 알림을 눌러 열 메일. 받은 편지함 목록이 오면 고른다.
    @ObservationIgnored private var pendingOpenID: String?
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

    // 본문
    var selectedMessageID: String? {
        didSet {
            guard selectedMessageID != oldValue else { return }
            allowRemoteFor = nil
            updateMenu()
            Task { await loadDetail() }
        }
    }
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
        if Store.isDemo {
            if signatures.signatures.isEmpty { DemoMailService.seedSignatures(into: signatures) }
            return AppModel(auth: auth, signatures: signatures, addressBook: addressBook, service: DemoMailService(),
                            notifier: RecordingNotifier(), isDemo: true)
        }
        return AppModel(auth: auth, signatures: signatures, addressBook: addressBook, service: GraphMailService(auth: auth),
                        notifier: SystemNotifier.shared, isDemo: false)
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
        do {
            folders = FolderOrder.sorted(try await service.folders())
            updateBadge()
        } catch {
            report(error)
        }
    }

    func loadMessages(keepSelection: Bool = false) async {
        guard let folderID = selectedFolderID else { return }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.messages(folderID: folderID, search: search.isEmpty ? nil : search)
            // 기다리는 사이 폴더나 검색어가 바뀌었으면 버린다.
            guard folderID == selectedFolderID, search == searchText.trimmingCharacters(in: .whitespaces) else { return }
            messages = page.messages
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
            messages += page.messages.filter { !known.contains($0.id) }
            nextLink = page.nextLink
        } catch {
            report(error)
        }
    }

    func loadDetail() async {
        guard let id = selectedMessageID else {
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
            guard id == selectedMessageID else { return }
            detail = m
            addressBook.noteSeen([m], me: auth.email)
            detailAttachments = attachments
            if let body = m.body {
                detailBody = body.isHTML
                    ? .init(contentType: body.contentType, content: MailContent.resolveInlineImages(html: body.content, attachments: attachments))
                    : body
            } else {
                detailBody = nil
            }
            updateMenu()
            if m.isUnread { await setRead(id: id, true) }
        } catch {
            report(error)
        }
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
            updateBadge()
            updateMenu()
        } catch {
            report(error)
        }
    }

    /// 목록에서 위아래 메일로 옮긴다. 끝에서는 그대로 있는다. 옮겼으면 true.
    @discardableResult
    func selectAdjacent(_ offset: Int) -> Bool {
        guard !messages.isEmpty else { return false }
        let current = messages.firstIndex { $0.id == selectedMessageID }
        let target = current.map { $0 + offset } ?? (offset > 0 ? 0 : messages.count - 1)
        guard messages.indices.contains(target) else { return false }
        selectedMessageID = messages[target].id
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

    func toggleReadSelected() async {
        guard let m = selectedMessage else { return }
        await setRead(id: m.id, m.isUnread)
    }

    func archiveSelected() async {
        await moveSelected(to: "archive", undoManager: nil, undoName: "보관")
    }

    func deleteSelected(undoManager: UndoManager?) async {
        await moveSelected(to: "deleteditems", undoManager: undoManager, undoName: "지우기")
    }

    /// 고른 메일을 옮기고 다음 메일을 고른다. 되돌리기는 원래 폴더로 다시 옮긴다.
    func moveSelected(to destination: String, undoManager: UndoManager?, undoName: String) async {
        guard let id = selectedMessageID, let index = messages.firstIndex(where: { $0.id == id }),
              let fromFolder = selectedFolderID else { return }
        do {
            let movedID = try await service.move(id: id, to: destination)
            messages.removeAll { $0.id == id }
            selectedMessageID = messages.isEmpty ? nil : messages[min(index, messages.count - 1)].id
            undoManager?.registerUndo(withTarget: self) { target in
                // 되돌리기는 메인 스레드에서 불린다.
                MainActor.assumeIsolated {
                    _ = Task { await target.restore(movedID: movedID, to: fromFolder) }
                }
            }
            undoManager?.setActionName(undoName)
            await loadFolders()
        } catch {
            report(error)
        }
    }

    func restore(movedID: String, to folderID: String) async {
        do {
            _ = try await service.move(id: movedID, to: folderID)
            await refresh()
        } catch {
            report(error)
        }
    }

    func allowRemoteContentForSelection() {
        allowRemoteFor = detail?.id
        updateMenu()
    }

    // MARK: 작성

    /// 고른 메일에서 답장·전달 초안을 만든다. 새 메시지는 빈 초안.
    func draft(_ kind: ComposeKind) -> ComposeDraft? {
        guard kind != .new else { return ComposeDraft() }
        guard let m = detail else { return nil }
        let body = detailBody?.isHTML == true
            ? detailBody?.content ?? ""
            : "<pre style=\"white-space:pre-wrap\">\(HTMLProcessor.escape(detailBody?.content ?? ""))</pre>"
        return ReplyBuilder.draft(kind: kind, message: m, bodyHTML: body, myAddress: auth.email)
    }

    // MARK: 새 메일 알림 (S-024)

    static func setting(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    var notifyNewMail: Bool { Self.setting("notify.newMail") }
    var notifySound: Bool { Self.setting("notify.sound") }
    var showBadge: Bool { Self.setting("notify.badge") }

    /// 로그인한 뒤 한 번: 알림을 켜 두었으면 권한을 묻는다(처음일 때만).
    func prepareNotifications() async {
        guard isSignedIn else { return }
        if notifyNewMail {
            notificationPermission = await notifier.requestPermission()
        } else {
            notificationPermission = await notifier.permission()
        }
    }

    func refreshNotificationPermission() async {
        notificationPermission = await notifier.permission()
    }

    /// 받은 편지함을 보고 새 메일을 알린다. 앱이 뒤에 있어도 2분마다 불린다. 오류는 조용히 넘긴다.
    func checkNewMail() async {
        guard isSignedIn else { return }
        loadTracker()
        guard let page = try? await service.messages(folderID: "inbox", search: nil) else { return }
        let fresh = tracker.take(page.messages)
        saveTracker()
        if notifyNewMail && notificationPermission == .allowed {
            for n in MailNotification.make(for: fresh) { notifier.post(n, sound: notifySound) }
        }
        if !fresh.isEmpty {
            await loadFolders()
            if selectedFolder?.kind == "inbox" && searchText.isEmpty { await loadMessages(keepSelection: true) }
        }
    }

    /// Dock 배지 = 받은 편지함의 읽지 않은 수. 설정에서 끄면 지운다.
    func updateBadge() {
        let unread = folders.first { $0.kind == "inbox" }?.unreadItemCount
        notifier.setBadge(showBadge && isSignedIn ? DockBadge.label(unread: unread) : nil)
    }

    /// 알림을 눌렀을 때: 받은 편지함에서 그 메일을 연다. 요약 알림(id 없음)은 받은 편지함만 연다.
    func openFromNotification(_ id: String?) async {
        guard isSignedIn else { return }
        let inboxID = folders.first { $0.kind == "inbox" }?.id ?? "inbox"
        pendingOpenID = id
        if selectedFolderID != inboxID {
            selectedFolderID = inboxID   // didSet이 목록을 불러오고 pendingOpenID를 고른다
        } else {
            searchText = ""
            await loadMessages(keepSelection: true)
        }
    }

    /// 새 메일 기준은 계정마다 UserDefaults에 둔다. 테스트 실행(APP_STORE)은 메모리에만.
    private var trackerKey: String { "newMail.tracker.\((auth.email ?? "").lowercased())" }

    private func loadTracker() {
        guard !trackerLoaded else { return }
        trackerLoaded = true
        guard !Store.isOverridden, let data = UserDefaults.standard.data(forKey: trackerKey),
              let saved = try? JSONDecoder().decode(NewMailTracker.self, from: data) else { return }
        tracker = saved
    }

    private func saveTracker() {
        guard !Store.isOverridden, let data = try? JSONEncoder().encode(tracker) else { return }
        UserDefaults.standard.set(data, forKey: trackerKey)
    }

    // MARK: 초안 (S-022)

    var isDraftSelected: Bool { selectedFolder?.kind == "drafts" && detail != nil }

    /// 임시 보관함의 고른 초안을 이어서 쓰는 시작 값.
    func resumeDraft() -> ComposeDraft? {
        guard isDraftSelected, let m = detail else { return nil }
        return ReplyBuilder.resume(draft: m, bodyHTML: detailBody?.content ?? "")
    }

    /// 초안을 저장하거나 지운 뒤: 폴더 수를 고치고, 임시 보관함을 보고 있으면 목록을 다시 읽는다.
    func draftsChanged() async {
        await loadFolders()
        if selectedFolder?.kind == "drafts" { await loadMessages(keepSelection: true) }
    }

    func save(attachment: FileAttachment) {
        guard let data = attachment.data else {
            errorMessage = "이 첨부는 파일이 아니라서 저장할 수 없습니다. Outlook 웹에서 열어 주세요."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FilenameEncoder.normalize(attachment.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            report(error)
        }
    }

    // MARK: helpers

    func report(_ error: Error) {
        if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
        errorMessage = error.localizedDescription
    }

    func updateMenu() {
        MenuState.shared.update(MenuSnapshot(
            signedIn: isSignedIn,
            hasMessage: detail != nil && selectedMessageID != nil,
            isUnread: selectedMessage?.isUnread ?? false,
            isDraft: isDraftSelected,
            hasRemoteContent: detailHasRemoteContent && !remoteContentAllowed))
    }
}
