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
        // 답장·전달은 원래 메일의 계정에서 보낸다 (M23)
        let owner = router.accountID(forMessage: m.id)
        let me = accounts.accounts.first { $0.id == owner }?.auth.email ?? auth.email
        var d = ReplyBuilder.draft(kind: kind, message: m, bodyHTML: html, myAddress: me)
        d.fromAccountID = owner
        // 설정 > 작성 > "원본 메시지의 텍스트를 인용"을 끄면 답장에 원문을 넣지 않는다 (전달은 늘 넣는다).
        if kind != .forward && !Prefs.bool(Prefs.quoteOriginal, true) { d.quoteHTML = "" }
        return d
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

    /// 모두 다운로드: 폴더를 고르면 첨부를 모두 NFC 이름으로 저장한다. 같은 이름이 있으면 번호를 붙인다.
    func saveAll(_ attachments: [FileAttachment], messageID: String? = nil) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("여기에 저장")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var skipped: [String] = []
        for original in attachments {
            guard let a = await loadedAttachment(original, messageID: messageID), let data = a.data else {
                skipped.append(original.name)
                continue
            }
            let name = FilenameEncoder.normalize(a.name)
            var url = dir.appending(path: name)
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                url = dir.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            do { try data.write(to: url) } catch { skipped.append(a.name) }
        }
        if !skipped.isEmpty {
            errorMessage = L("저장하지 못한 첨부: \(skipped.joined(separator: ", ")). Outlook 웹에서 받아 주세요.")
        }
    }

    /// 다운로드…: 내용이 빠진 첨부는 서버에서 받아 저장한다.
    func save(attachment: FileAttachment, messageID: String? = nil) async {
        guard let full = await loadedAttachment(attachment, messageID: messageID), let data = full.data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FilenameEncoder.normalize(full.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            report(error)
        }
    }
}
