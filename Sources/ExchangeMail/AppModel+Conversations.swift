import ExchangeMailKit
import Foundation

/// 대화별로 묶어 보기 (S-025).
extension AppModel {
    /// 보기 > 대화별로 정리. 화면은 @AppStorage("list.threaded")로, 동작(옮기기, 위아래 이동)은 이 값으로.
    static var organizeByConversation: Bool {
        UserDefaults.standard.object(forKey: "list.threaded") as? Bool ?? true
    }

    /// 지금 폴더 목록을 대화로 묶은 것
    /// 목록이 그려질 때마다 불린다. 메일·관련 메일·정렬이 그대로면 지난번 결과를 쓴다
    /// (수백 통을 대화로 묶는 일을 스크롤·선택 때마다 되풀이하지 않게).
    var conversations: [Conversation] {
        var hasher = Hasher()
        hasher.combine(messages)
        hasher.combine(relatedMessages)
        hasher.combine(listSort.key)
        hasher.combine(listSort.descending)
        let key = hasher.finalize()
        if let memo = conversationMemo, memo.key == key { return memo.value }
        let value = groupConversations()
        conversationMemo = (key, value)
        return value
    }

    private func groupConversations() -> [Conversation] {
        let groups = Conversations.group(messages, related: relatedMessages)
        // 정렬 기준이 날짜 내림차순이 아니면 대화의 최근 메일로 정렬한다 (S-042).
        guard listSort != MailSort() else { return groups }
        let order = listSort.apply(groups.map(\.latest)).map(\.id)
        let index = Dictionary(uniqueKeysWithValues: groups.map { ($0.latest.id, $0) })
        return order.compactMap { index[$0] }
    }

    /// 목록에서 위아래로 옮길 때의 순서: 대화별이면 대화의 최근 메일, 아니면 메일 하나하나.
    var navigationOrder: [String] {
        Self.organizeByConversation ? conversations.map(\.latest.id) : messages.map(\.id)
    }

    /// 이 폴더에서 그 메일과 같은 대화인 메일 id (대화가 없으면 그 메일만)
    func conversationMessageIDs(containing id: String) -> [String] {
        guard let conv = messages.first(where: { $0.id == id })?.conversationId, !conv.isEmpty else { return [id] }
        return messages.filter { $0.conversationId == conv }.map(\.id)
    }

    /// 대화에 세지 않는 폴더: 임시 보관함, 지운 편지함, 정크 메일, 보낼 편지함 (지금 그 폴더를 보고 있으면 센다).
    /// 목록 줄의 수(loadRelated)와 본문 위 대화 목록(loadThread)이 같은 규칙을 쓴다.
    var threadExcludedFolderIDs: Set<String> {
        let kinds: Set<String> = ["drafts", "deleteditems", "junkemail", "outbox"]
        var ids = Set(folders.filter { kinds.contains($0.kind ?? "") }.map(\.id)).union(kinds)
        if let current = selectedFolderID { ids.remove(current) }
        if let kind = selectedFolder?.kind { ids.remove(kind) }
        return ids
    }

    /// 고른 메일의 대화 전체를 가져온다. 목록 줄이 제목으로 여러 대화를 합쳤으면 그 대화들을 모두 가져온다.
    /// 다 가져오면 목록 줄의 수도 이 수로 맞춘다 (threadCounts). 대화별로 정리 중이면 그 대화 안 읽은 메일을 읽음으로.
    func loadThread() async {
        guard let id = selectedMessageID, messages.contains(where: { $0.id == id }) else {
            thread = []
            return
        }
        // 목록 줄 (대화별 정리일 때) 또는 그 메일 하나
        let row = Self.organizeByConversation ? conversations.first { $0.messages.contains { $0.id == id } } : nil
        let members = row.map { $0.messages + $0.related } ?? messages.filter { $0.id == id }
        var conversationIDs: [String] = []
        for m in members {
            if let c = m.conversationId, !c.isEmpty, !conversationIDs.contains(c) { conversationIDs.append(c) }
        }
        guard !conversationIDs.isEmpty else {
            thread = []
            return
        }
        do {
            var list: [MailMessage] = []
            var seen = Set<String>()
            // 1분 안에 받은 대화는 다시 묻지 않는다 (↓↑로 같은 대화 안을 오갈 때). 합쳐진 대화는 많아야 넷.
            for conv in conversationIDs.prefix(4) {
                let part: [MailMessage]
                if let cached = threadCache[conv], Date().timeIntervalSince(cached.at) < 60 {
                    part = cached.list
                } else {
                    part = try await service.conversation(id: conv)
                    threadCache[conv] = (Date(), part)
                }
                for m in part where seen.insert(m.id).inserted { list.append(m) }
            }
            if threadCache.count > 100 { threadCache = threadCache.filter { Date().timeIntervalSince($0.value.at) < 60 } }
            guard id == selectedMessageID else { return }
            // 임시 보관함·지운 편지함·정크·보낼 편지함의 메일은 대화에 넣지 않는다 (고른 메일은 남긴다).
            let excluded = threadExcludedFolderIDs
            var ordered = Conversations.chronological(list).filter {
                $0.id == id || $0.parentFolderId.map { !excluded.contains($0) } ?? true
            }
            // 설정 > 보기 > "관련된 메시지 포함"을 끄면 이 폴더의 메일만
            if !Prefs.bool(Prefs.threadAllFolders, true), let folder = selectedFolderID, !VirtualMailbox.isVirtual(folder) {
                ordered = ordered.filter { $0.parentFolderId == nil || $0.parentFolderId == folder || $0.id == id }
            }
            thread = ordered
            // 목록 줄의 수를 실제 대화 수로 (한 번 연 대화는 같은 수가 보인다)
            if let row, ordered.count != row.count { threadCounts[row.id] = ordered.count }
            if Self.organizeByConversation, let row {
                for m in row.messages where m.isUnread && m.id != id {
                    await setRead(id: m.id, true)
                }
            }
        } catch {
            // 대화를 못 가져와도 고른 메일 본문은 보인다.
            thread = []
        }
    }

    /// 다른 폴더에 있는 대화 메일의 꼬리표 (예: "보낸 편지함"). 지금 폴더면 nil.
    func folderTag(for m: MailMessage) -> String? {
        guard let folder = m.parentFolderId, folder != selectedFolderID else { return nil }
        return folders.first { $0.id == folder }?.displayName
    }
}
