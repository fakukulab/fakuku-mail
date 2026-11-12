import ExchangeMailKit
import Foundation

/// 메시지 회수 (S-071). Outlook의 "메시지 회수"와 같은 Exchange Online 클라우드 메시지 회수.
/// - Exchange 계정의 보낸 편지함 메일만. iCloud·Gmail(IMAP)에는 회수가 없다.
/// - 같은 조직의 Exchange Online 사서함에서만 지워진다. 조직 밖(Gmail 등)으로 간 메일은 회수되지 않는다.
/// - 요청은 바로 접수(202)되고, 받는 사람마다의 결과는 서버가 "메시지 회수 보고서" 메일로 보낸다.
extension AppModel {

    /// 이 메일을 회수할 수 있는가: Exchange 계정 보낸 편지함의 메일
    func canRecall(_ m: MailMessage?) -> Bool {
        guard let m, let folder = m.parentFolderId ?? selectedFolderID else { return false }
        return accounts.accounts.contains { a in
            a.imap == nil && (accountFolders[a.id] ?? []).contains { $0.id == folder && $0.kind == "sentitems" }
        }
    }

    /// 메뉴·오른쪽 클릭: 확인 창을 띄운다
    func askRecall(_ m: MailMessage?) {
        guard let m, canRecall(m) else { return }
        recallTarget = m
    }

    /// 확인 창에서 "회수"
    func recall(_ m: MailMessage) async {
        do {
            try await service.recall(id: m.id)
            noticeMessage = L("회수를 요청했습니다. 같은 조직의 Exchange Online 사서함에서만 회수되며, 받는 사람마다의 결과는 \"메시지 회수 보고서\" 메일로 옵니다.")
        } catch {
            report(error, quietIfOffline: false)
        }
    }
}
