import AppKit
import ExchangeMailKit
import Observation
import SwiftUI

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    let auth: GraphAuth
    let signatures: SignatureStore
    let isDemo: Bool
    @ObservationIgnored let service: any MailService

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

    init(auth: GraphAuth, signatures: SignatureStore, service: any MailService, isDemo: Bool) {
        self.auth = auth
        self.signatures = signatures
        self.service = service
        self.isDemo = isDemo
    }

    static func make() -> AppModel {
        let signatures = SignatureStore(url: Store.directory.appending(path: "signatures.json"))
        let auth = GraphAuth(demoEmail: Store.isDemo ? DemoMailService.myAddress : nil)
        if Store.isDemo {
            if signatures.signatures.isEmpty { DemoMailService.seedSignatures(into: signatures) }
            return AppModel(auth: auth, signatures: signatures, service: DemoMailService(), isDemo: true)
        }
        return AppModel(auth: auth, signatures: signatures, service: GraphMailService(auth: auth), isDemo: false)
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
            nextLink = page.nextLink
            if !(keepSelection && messages.contains { $0.id == selectedMessageID }) {
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
            updateMenu()
        } catch {
            report(error)
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
            hasRemoteContent: detailHasRemoteContent && !remoteContentAllowed))
    }
}
