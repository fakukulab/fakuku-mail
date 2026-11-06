import Foundation

// MARK: .eml 파일 한 통 열기 (1.0.1)
//
// 첨부로 온 메일(.eml, 받은 메일의 첨부된 메일)이나 Finder에서 연 .eml 파일을 FAKUKU Mail에서 읽고,
// 답장·전체 답장·전달·새 메시지로 편집한다. 읽기는 `MailArchive.parse`, 답장 규칙은 `ReplyBuilder`를 그대로 쓴다.

public enum EMLMessage {

    /// 메일 파일로 보는 첨부: .eml 확장자, message/rfc822
    public static func isMail(name: String, contentType: String?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "eml" || ext == "emlx" || (contentType ?? "").lowercased().hasPrefix("message/rfc822")
    }

    /// 보관 메일을 답장 규칙(`ReplyBuilder`)이 읽는 메일 모양으로. 서버에 있는 메일이 아니므로 첨부는 서버에서 가져오지 않는다.
    public static func message(_ mail: ArchivedMail) -> MailMessage {
        let headers = mail.references.isEmpty
            ? nil : [InternetHeader(name: "References", value: mail.references.joined(separator: " "))]  // l10n: data
        return MailMessage(id: "eml:\(mail.id)", internetMessageId: mail.messageID, subject: mail.subject,  // l10n: data
                           from: recipients(mail.from).first, toRecipients: recipients(mail.to),
                           ccRecipients: recipients(mail.cc), receivedDateTime: mail.date,
                           hasAttachments: false, internetMessageHeaders: headers)
    }

    static func recipients(_ field: String) -> [Recipient] {
        AddressParser.parse(field).valid.map { Recipient(name: $0.name, address: $0.address) }
    }

    /// 인용할 본문 HTML: 본문 그림은 data: 주소로, 글자 메일은 줄을 지킨 <pre>로. 스크립트는 뺀다.
    public static func bodyHTML(_ mail: ArchivedMail) -> String {
        if let html = MailArchive.inlineImages(mail) {
            return html.replacingOccurrences(of: #"(?is)<script\b.*?</script\s*>"#, with: "", options: .regularExpression)
        }
        return "<pre style=\"white-space:pre-wrap\">\(HTMLProcessor.escape(mail.text ?? ""))</pre>"
    }

    /// 답장·전체 답장·전달의 시작 값. Reply-To가 있으면 답장은 그 주소로 간다 (메일링 리스트, 대신 보낸 메일).
    /// 전달할 첨부 파일은 앱이 임시 파일로 써서 `ComposeDraft.attachFiles`에 넣는다.
    public static func draft(kind: ComposeKind, mail: ArchivedMail, myAddress: String?,
                             timeZone: TimeZone = .current) -> ComposeDraft {
        guard kind != .new else { return editAsNew(mail) }
        var d = ReplyBuilder.draft(kind: kind, message: message(mail), bodyHTML: bodyHTML(mail),
                                   myAddress: myAddress, timeZone: timeZone)
        d.forwardAttachmentsFrom = nil
        if kind == .reply || kind == .replyAll {
            let me = (myAddress ?? "").lowercased()
            let replyTo = AddressParser.parse(mail.replyTo).valid.filter { $0.address.lowercased() != me }
            if !replyTo.isEmpty {
                d.to = AddressParser.format(replyTo)
                let cc = AddressParser.parse(d.cc).valid
                    .filter { c in !replyTo.contains { $0.address.lowercased() == c.address.lowercased() } }
                d.cc = AddressParser.format(cc)
            }
        }
        return d
    }

    /// 새 메시지로 편집: 받는 사람·참조·제목·본문을 그대로 옮긴 새 메일 (서명과 인용은 넣지 않는다).
    public static func editAsNew(_ mail: ArchivedMail) -> ComposeDraft {
        var d = ComposeDraft(kind: .new)
        d.to = AddressParser.format(AddressParser.parse(mail.to).valid)
        d.cc = AddressParser.format(AddressParser.parse(mail.cc).valid)
        d.subject = mail.subject
        d.bodyHTML = ReplyBuilder.extractBody(bodyHTML(mail))
        return d
    }
}
