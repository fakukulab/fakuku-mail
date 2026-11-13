import AppKit
import ExchangeMailKit
import Foundation

/// 사이드바 메일상자의 오른쪽 클릭 메뉴 (S-073). 맥 Mail과 같은 차례:
/// 새로운 메일상자 · 즐겨찾기 · 내보내기 · 삭제된 항목/정크 메일 지우기 · 모두 읽음 · 계정 동기화·편집 · 부재 중 · 계정 정보.
extension AppModel {
    /// 메일상자(서버 폴더)의 계정
    func account(ofFolder folder: MailFolder) -> MailAccount? {
        let id = router.accountID(forFolder: folder.id)
        return accounts.accounts.first { $0.id == id } ?? accounts.active
    }

    // MARK: 즐겨찾기

    /// 즐겨찾기 폴더 (사이드바 차례). 사라진 폴더는 건너뛴다.
    var favoriteFolders: [MailFolder] {
        let all = accounts.accounts.flatMap { accountFolders[$0.id] ?? [] } + (accountFolders.isEmpty ? folders : [])
        return mailboxes.favorites.compactMap { id in all.first { $0.id == id } }
    }

    func toggleFavorite(_ folder: MailFolder) {
        if mailboxes.isFavorite(folder.id) { mailboxes.removeFavorite(folder.id) } else { mailboxes.addFavorite(folder.id) }
    }

    /// 즐겨찾기 메일상자 추가…: 아직 즐겨찾기가 아닌 폴더를 골라 넣는다
    func chooseFavorite() {
        let choices = accounts.accounts.flatMap { a in
            (accountFolders[a.id] ?? []).filter { !mailboxes.isFavorite($0.id) }.map { (account: a, folder: $0) }
        }
        guard !choices.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("즐겨찾기 메일상자 추가")
        alert.informativeText = L("사이드바 맨 위 즐겨찾기에 둘 메일상자를 고르세요.")
        alert.addButton(withTitle: L("추가"))
        alert.addButton(withTitle: L("취소"))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28), pullsDown: false)
        let several = accounts.accounts.count > 1
        for c in choices {
            let indent = String(repeating: "    ", count: c.folder.depth ?? 0)
            popup.addItem(withTitle: indent + c.folder.displayName + (several ? " — \(accounts.title(for: c.account))" : ""))
        }
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0 else { return }
        mailboxes.addFavorite(choices[popup.indexOfSelectedItem].folder.id)
    }

    // MARK: 지우기

    /// 삭제된 항목 지우기 / 정크 메일 지우기: 그 메일상자의 계정에서 (메뉴 막대와 같은 확인을 거친다)
    func emptyFolder(kind: String, account: MailAccount) {
        activateAccount(account.id)
        let count = folderCount(kind: kind)
        let ok = kind == "deleteditems"
            ? TextPrompt.confirm(L("지운 편지함을 비울까요?"),
                                 message: L("지운 편지함의 메일 \(count)통을 영구히 지웁니다. 되돌릴 수 없습니다."), action: L("비우기"))
            : TextPrompt.confirm(L("정크 메일을 지울까요?"),
                                 message: L("정크 메일 폴더의 메일 \(count)통을 지운 편지함으로 옮깁니다."), action: L("지우기"))
        if ok { Task { await emptyFolder(kind: kind) } }
    }

    // MARK: 계정

    /// '계정' 동기화: 그 계정의 폴더와 지금 목록을 서버에서 다시 읽는다
    func syncAccount(_ account: MailAccount) async {
        progressText = L("동기화하는 중…")
        defer { progressText = nil }
        do {
            accountFolders[account.id] = FolderOrder.tree(try await router.folders(of: account))
            if accounts.activeID == account.id { folders = accountFolders[account.id] ?? folders }
        } catch {
            report(error, quietIfOffline: false)
        }
        await loadMessages(keepSelection: true)
        updateBadge()
    }

    /// 계정 정보 가져오기: 계정 종류, 주소, 메일상자와 메일 수
    func showAccountInfo(_ account: MailAccount) {
        let list = accountFolders[account.id] ?? []
        let total = list.reduce(0) { $0 + ($1.totalItemCount ?? 0) }
        let unread = list.reduce(0) { $0 + ($1.unreadItemCount ?? 0) }
        let alert = NSAlert()
        alert.messageText = accounts.title(for: account)
        var lines = [
            L("종류: \(account.kindName)"),
            L("주소: \(account.email)"),
            L("메일상자: \(list.count)개"),
            L("메일: \(total)통 (읽지 않음 \(unread)통)"),
        ]
        if let imap = account.imap { lines.append(L("서버: \(imap.imapHost)")) }
        lines.append(isOffline ? L("상태: 오프라인") : L("상태: 연결됨"))
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: L("확인"))
        alert.runModal()
    }

    // MARK: 내보내기

    /// 메일상자 내보내기…: 서버 폴더의 모든 메일을 원본 그대로 .mbox 파일 하나로 저장한다
    func exportFolder(_ folder: MailFolder) {
        let panel = NSSavePanel()
        panel.title = L("메일상자 내보내기")
        panel.prompt = L("내보내기")
        panel.nameFieldStringValue = "\(folder.displayName.replacingOccurrences(of: "/", with: "-")).mbox"
        panel.allowedContentTypes = [Self.mboxType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await exportFolder(folder, to: url) }
    }

    /// 내보낸 메일 수. 실패하면 nil (오류는 알린다). 셀프 테스트도 부른다.
    @discardableResult
    func exportFolder(_ folder: MailFolder, to url: URL) async -> Int? {
        progressText = L("내보내는 중…")
        defer { progressText = nil }
        var out = Data()
        var done = 0
        do {
            var page = try await service.messages(folderID: folder.id, search: nil)
            for _ in 0..<2000 {
                for m in page.messages {
                    let mime = try await service.mimeContent(id: m.id)
                    out.append(MailArchive.mboxEntry(mime, date: m.receivedDateTime))
                    done += 1
                    progressText = L("내보내는 중… \(done)통")
                }
                guard let next = page.nextLink else { break }
                page = try await service.nextPage(next)
            }
            try out.write(to: url, options: .atomic)
            if !Store.isOverridden { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return done
        } catch {
            report(error, quietIfOffline: false)
            return nil
        }
    }
}
