import ExchangeMailKit
import Foundation

/// 대화별로 묶어 보기 (S-025).
extension AppModel {
    /// 보기 > 대화별로 정리. 화면은 @AppStorage("list.threaded")로, 동작(옮기기, 위아래 이동)은 이 값으로.
    static var organizeByConversation: Bool {
        UserDefaults.standard.object(forKey: "list.threaded") as? Bool ?? true
    }

    /// 지금 폴더 목록을 대화로 묶은 것
    var conversations: [Conversation] { Conversations.group(messages) }

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
            let list = try await service.conversation(id: conv)
            guard id == selectedMessageID else { return }
            thread = Conversations.chronological(list)
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
