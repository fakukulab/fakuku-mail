import AppKit
import ExchangeMailKit
import Foundation

/// 맥 Mail 메뉴에 맞춘 동작 (M17): 다시 보내기, 첨부 파일로 전달, 우선 순위, 복사, 마지막 폴더로 다시 이동,
/// 대화 알림 끄기, 모두 읽음, 지운 편지함·정크 메일 비우기, 이전·다음 메일상자.
extension AppModel {

    // MARK: 메시지

    /// 다시 보내기: 보낸 메일과 같은 받는 사람·제목·본문·첨부로 새 메일을 연다. 원본은 그대로 둔다.
    func sendAgainDraft() -> ComposeDraft? {
        guard let m = detail else { return nil }
        var d = ReplyBuilder.resume(draft: m, bodyHTML: detailBody?.content ?? "")
        d.draftMessageID = nil   // 원본을 초안으로 보고 지우지 않게
        d.references = []
        d.inReplyTo = nil
        return d
    }

    /// 첨부 파일로 전달: 원본 메일 전체(.eml)를 붙인 새 전달 메일
    func forwardAsAttachmentDraft() -> ComposeDraft? {
        guard let m = detail else { return nil }
        var d = ComposeDraft(kind: .forward, subject: ReplyBuilder.subject(for: .forward, original: m.subject ?? ""))
        d.attachMessageFrom = m.id
        d.attachMessageName = m.title
        return d
    }

    /// 우선 순위 설정: low, normal, high
    func setImportanceSelected(_ importance: String) async {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try await service.setImportance(id: id, importance: importance)
                if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].importance = importance }
                patchDetail(id) { $0.importance = importance }
            }
            updateMenu()
        } catch {
            report(error, quietIfOffline: false)
        }
    }

    /// 다음으로 복사: 고른 메일을 그 폴더에 복사한다 (원본은 남는다).
    func copySelected(to destination: String) async {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        do {
            for id in ids { try await service.copy(id: id, to: destination) }
            await loadFolders()
        } catch {
            report(error, quietIfOffline: false)
        }
    }

    /// 'X'(으)로 다시 이동 (⌃⌘M)
    func moveSelectedToLastTarget(undoManager: UndoManager?) async {
        guard let target = lastMoveTarget else { return }
        await moveSelected(to: target.id, undoManager: undoManager, undoName: L("이동"))
    }

    /// 고른 메일의 대화 id들
    private var selectedConversationIDs: Set<String> {
        Set(messages.filter { selectedIDs.contains($0.id) }.compactMap(\.conversationId))
    }

    /// 고른 대화의 알림이 꺼져 있는지
    var selectionIsMuted: Bool {
        let ids = selectedConversationIDs
        return !ids.isEmpty && ids.isSubset(of: mutedConversations)
    }

    /// 알림 비활성화 / 활성화 (⌃⇧M): 이 대화에 새 메일이 와도 알리지 않는다.
    func toggleMuteSelected() {
        let ids = selectedConversationIDs
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: mutedConversations) {
            mutedConversations.subtract(ids)
        } else {
            mutedConversations.formUnion(ids)
        }
    }

    // MARK: 메일상자

    /// 모든 메시지를 읽음으로 표시: 지금 폴더의 읽지 않은 메일 (서버 폴더만)
    func markAllReadInFolder() async {
        guard let folderID = selectedFolderID, !VirtualMailbox.isVirtual(folderID) else { return }
        var unread = MailFilter()
        unread.unread = true
        progressText = L("읽음으로 표시하는 중…")
        defer { progressText = nil }
        do {
            var page = try await service.messages(folderID: folderID, search: nil, filter: unread, oldestFirst: false)
            var done = 0
            while true {
                for m in page.messages where m.isUnread {
                    try await service.setRead(id: m.id, read: true)
                    done += 1
                    progressText = L("읽음으로 표시하는 중… \(done)통")
                }
                guard let next = page.nextLink, done < 5_000 else { break }
                page = try await service.nextPage(next)
            }
            await refresh()
            updateBadge()
        } catch {
            report(error, quietIfOffline: false)
            await refresh()
        }
    }

    /// 지운 편지함 비우기(영구 삭제) 또는 정크 메일 지우기(지운 편지함으로). `kind`는 deleteditems, junkemail.
    func emptyFolder(kind: String) async {
        let folderID = folders.first { $0.kind == kind }?.id ?? kind
        progressText = kind == "deleteditems" ? L("지운 편지함을 비우는 중…") : L("정크 메일을 지우는 중…")
        defer { progressText = nil }
        var done = 0
        do {
            // 지우면 다음 쪽 링크가 어긋나므로 매번 첫 쪽을 다시 읽는다.
            for _ in 0..<200 {
                let page = try await service.messages(folderID: folderID, search: nil)
                guard !page.messages.isEmpty else { break }
                for m in page.messages {
                    try await service.deleteMessage(id: m.id)
                    done += 1
                    progressText = L("\(kind == "deleteditems" ? L("지운 편지함을 비우는 중") : L("정크 메일을 지우는 중"))… \(done)통")
                }
            }
        } catch {
            report(error, quietIfOffline: false)
        }
        await refresh()
    }

    func folderCount(kind: String) -> Int {
        folders.first { $0.kind == kind }?.totalItemCount ?? 0
    }

    /// 사이드바 순서: 깃발 표시, 스마트 메일상자, VIP, 서버 폴더
    var sidebarOrder: [String] {
        var ids = [FolderOrder.flaggedID] + mailboxes.smart.map(\.id)
        if !mailboxes.vips.isEmpty {
            ids += [VirtualMailbox.allVIPsID] + mailboxes.vips.map { VirtualMailbox.id(forVIP: $0.address) }
        }
        return ids + folders.map(\.id) + localBoxes.boxes.map(\.sidebarID)
    }

    /// 이전·다음 메일상자 (⌃⌘[, ⌃⌘])
    func selectAdjacentMailbox(_ offset: Int) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let current = selectedFolderID.flatMap { order.firstIndex(of: $0) } ?? 0
        let target = min(max(current + offset, 0), order.count - 1)
        selectedFolderID = order[target]
    }

    /// 스마트 메일상자 복제
    func duplicateSmart(id: String) {
        guard var copy = mailboxes.smart.first(where: { $0.id == id }) else { return }
        copy.id = SmartMailbox.newID()
        copy.name += L(" 사본")
        saveSmart(copy)
    }

    /// 지금 고른 서버 폴더 (이름 변경·지우기 메뉴)
    var selectedEditableFolder: MailFolder? {
        guard let f = selectedFolder, f.isEditable else { return nil }
        return f
    }
}
