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

    /// 고른 메일의 대화 전체를 가져온다. 대화별로 정리 중이면 이 폴더의 그 대화 안 읽은 메일을 읽음으로.
    func loadThread() async {
        guard let id = selectedMessageID,
              let conv = messages.first(where: { $0.id == id })?.conversationId, !conv.isEmpty else {
            thread = []
            return
        }
        do {
            let list: [MailMessage]
            // 1분 안에 받은 대화는 다시 묻지 않는다 (↓↑로 같은 대화 안을 오갈 때).
            if let cached = threadCache[conv], Date().timeIntervalSince(cached.at) < 60 {
                list = cached.list
            } else {
                list = try await service.conversation(id: conv)
                threadCache[conv] = (Date(), list)
                if threadCache.count > 100 { threadCache = threadCache.filter { Date().timeIntervalSince($0.value.at) < 60 } }
            }
            guard id == selectedMessageID else { return }
            var ordered = Conversations.chronological(list)
            // 설정 > 보기 > "관련된 메시지 포함"을 끄면 이 폴더의 메일만
            if !Prefs.bool(Prefs.threadAllFolders, true), let folder = selectedFolderID, !VirtualMailbox.isVirtual(folder) {
                ordered = ordered.filter { $0.parentFolderId == nil || $0.parentFolderId == folder || $0.id == id }
            }
            thread = ordered
            if Self.organizeByConversation {
                for m in messages where m.conversationId == conv && m.isUnread && m.id != id {
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
