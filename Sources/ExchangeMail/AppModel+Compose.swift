import AppKit
import ExchangeMailKit
import Foundation

/// 답장·전달 초안, 임시 보관함 초안 이어서 쓰기, 첨부 저장 (S-007, S-005, S-022)
extension AppModel {
    // MARK: 작성

    /// 고른 메일에서 답장·전달 초안을 만든다. 새 메시지는 빈 초안.
    func draft(_ kind: ComposeKind) -> ComposeDraft? {
        guard kind != .new else { return ComposeDraft() }
        guard let m = detail else { return nil }
        return draft(kind, message: m, body: detailBody)
    }

    /// 메일 한 통(본문 열 또는 메시지 창, S-043)에 대한 답장·전달 시작 값
    func draft(_ kind: ComposeKind, message m: MailMessage, body: MailMessage.Body?) -> ComposeDraft? {
        guard kind != .new else { return ComposeDraft() }
        let html = body?.isHTML == true
            ? body?.content ?? ""
            : "<pre style=\"white-space:pre-wrap\">\(HTMLProcessor.escape(body?.content ?? ""))</pre>"
        return ReplyBuilder.draft(kind: kind, message: m, bodyHTML: html, myAddress: auth.email)
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
}
