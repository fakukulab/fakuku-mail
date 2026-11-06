import Foundation

/// 작성 창 하나의 시작 값. 창을 다시 열 때 복원되도록 Codable.
public struct ComposeDraft: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: ComposeKind = .new
    public var to = ""
    public var cc = ""
    public var bcc = ""
    public var subject = ""
    /// 본문 끝에 붙는 인용문 (`data-quote` div). 인라인 그림은 data: URI로 들어 있다.
    public var quoteHTML = ""
    /// 답장하는 원본의 Message-ID
    public var inReplyTo: String?
    public var references: [String] = []
    /// 전달할 때(또는 초안을 다시 열 때) 첨부를 가져올 메시지 id (Graph id)
    public var forwardAttachmentsFrom: String?
    /// 다시 연 초안의 id. 다시 저장하거나 보내면 이 초안을 지운다 (S-022).
    public var draftMessageID: String?
    /// 다시 연 초안의 본문 전체. 있으면 서명과 인용문을 새로 넣지 않는다.
    public var bodyHTML: String?
    /// 첨부 파일로 전달: 이 메일의 원본(.eml)을 붙인다 (M17)
    public var attachMessageFrom: String?
    /// 붙일 .eml 파일 이름 (확장자 없이)
    public var attachMessageName: String?
    /// 보낼 계정 (M23). nil이면 지금 계정. 답장·전달은 원래 메일의 계정.
    public var fromAccountID: String?
    /// 붙일 이 Mac의 파일 (1.1: .eml 메일을 전달하거나 새 메시지로 편집할 때 그 첨부)
    public var attachFiles: [URL] = []
    /// mailto: 링크의 body (글자). 서명 앞, 본문 첫머리에 들어간다.
    public var bodyText: String?

    public init(kind: ComposeKind = .new, to: String = "", subject: String = "") {
        self.kind = kind
        self.to = to
        self.subject = subject
    }

    /// mailto: 링크로 새 메시지 (RFC 6068): 받는 사람, 참조, 숨은 참조, 제목, 본문.
    /// 본문의 링크, 그리고 기본 이메일 앱일 때 다른 앱(웹 브라우저 등)의 링크가 쓴다.
    public static func mailto(_ url: URL) -> ComposeDraft {
        let raw = url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: [.anchored, .caseInsensitive])  // l10n: data
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var to = [parts.first?.removingPercentEncoding ?? ""]
        var cc: [String] = []
        var bcc: [String] = []
        var subject = ""
        var body: String?
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let value = kv[1].removingPercentEncoding ?? kv[1]
                switch kv[0].lowercased() {
                case "to": to.append(value)
                case "cc": cc.append(value)
                case "bcc": bcc.append(value)
                case "subject": subject = value
                case "body": body = value
                default: break
                }
            }
        }
        func joined(_ list: [String]) -> String {
            list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        var draft = ComposeDraft(to: joined(to), subject: subject)
        draft.cc = joined(cc)
        draft.bcc = joined(bcc)
        draft.bodyText = body.flatMap { $0.isEmpty ? nil : $0 }
        return draft
    }

    /// `bodyText`를 편집기에 넣을 HTML로 (줄마다 div)
    public var bodyTextHTML: String? {
        guard let bodyText else { return nil }
        let lines = bodyText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return lines.map { $0.isEmpty ? "<div><br></div>" : "<div>\(HTMLProcessor.escape($0))</div>" }.joined()
    }
}

public enum ReplyBuilder {

    static let replyPrefixes = ["re:", "회신:", "답장:", "aw:", "sv:"]  // l10n: data
    static let forwardPrefixes = ["fw:", "fwd:", "전달:", "wg:", "tr:"]  // l10n: data

    /// 답장은 "RE: ", 전달은 "FW: "를 한 번만 붙인다.
    public static func subject(for kind: ComposeKind, original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        switch kind {
        case .new:
            return trimmed
        case .reply, .replyAll:
            return replyPrefixes.contains { lower.hasPrefix($0) } ? trimmed : "RE: " + trimmed
        case .forward:
            return forwardPrefixes.contains { lower.hasPrefix($0) } ? trimmed : "FW: " + trimmed
        }
    }

    /// 답장 받는 사람: 보낸 사람. 전체 답장은 원본의 받는 사람·참조를 참조로, 내 주소는 뺀다.
    public static func recipients(for kind: ComposeKind, message m: MailMessage, myAddress: String?)
        -> (to: [MailAddress], cc: [MailAddress]) {
        guard kind == .reply || kind == .replyAll else { return ([], []) }
        let me = (myAddress ?? "").lowercased()
        let sender = m.from?.emailAddress.mailAddress
        var to = [sender].compactMap { $0 }
        var cc: [MailAddress] = []
        if kind == .replyAll {
            let others = ((m.toRecipients ?? []) + (m.ccRecipients ?? [])).compactMap { $0.emailAddress.mailAddress }
            for a in others {
                let key = a.address.lowercased()
                if key == me { continue }
                if to.contains(where: { $0.address.lowercased() == key }) { continue }
                if cc.contains(where: { $0.address.lowercased() == key }) { continue }
                cc.append(a)
            }
            // 내가 보낸 메일에 전체 답장: 보낸 사람이 나라면 원래 받는 사람에게 보낸다.
            if to.first?.address.lowercased() == me {
                to = (m.toRecipients ?? []).compactMap { $0.emailAddress.mailAddress }
                    .filter { $0.address.lowercased() != me }
                cc.removeAll { c in to.contains { $0.address.lowercased() == c.address.lowercased() } }
            }
        }
        return (to, cc)
    }

    /// 인용문 HTML. `bodyHTML`은 화면에 보이던 본문(인라인 그림이 data: URI로 바뀐 것)이다.
    public static func quoteHTML(for kind: ComposeKind, message m: MailMessage, bodyHTML: String,
                                 timeZone: TimeZone = .current) -> String {
        let when = m.receivedDateTime.map { MailDate.long($0, timeZone: timeZone) } ?? ""
        let from = HTMLProcessor.escape(m.from?.emailAddress.mailAddress?.editable ?? m.from?.emailAddress.display ?? "")
        let body = extractBody(bodyHTML)
        if kind == .forward {
            let to = HTMLProcessor.escape(AddressParser.format((m.toRecipients ?? []).compactMap { $0.emailAddress.mailAddress }))
            let cc = HTMLProcessor.escape(AddressParser.format((m.ccRecipients ?? []).compactMap { $0.emailAddress.mailAddress }))
            var header = L("<b>보낸 사람:</b> \(from)<br><b>날짜:</b> \(HTMLProcessor.escape(when))<br><b>받는 사람:</b> \(to)<br>")
            if !cc.isEmpty { header += L("<b>참조:</b> \(cc)<br>") }
            header += L("<b>제목:</b> \(HTMLProcessor.escape(m.title))")
            return """
            <div data-quote="forward"><br><div>-------- \(L("전달된 메시지")) --------</div>\
            <div style="font-size:12px">\(header)</div><br>\(body)</div>
            """
        }
        return """
        <div data-quote="reply"><br><div style="font-size:12px">\(L("\(HTMLProcessor.escape(when)), \(from) 님이 작성:"))</div>\
        <blockquote type="cite" style="margin:4px 0 0 0;padding-left:10px;border-left:2px solid #b4b4b4">\(body)</blockquote></div>
        """
    }

    /// 전체 HTML 문서에서 `<body>` 안쪽만 꺼낸다. 인용 블록 안에 `<html>`이 겹치지 않게.
    static func extractBody(_ html: String) -> String {
        guard let open = html.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else {
            return html.range(of: #"<html\b"#, options: [.regularExpression, .caseInsensitive]) == nil
                ? html : html.replacingOccurrences(of: #"(?is)<head\b.*?</head>|</?(html|body)\b[^>]*>"#, with: "", options: .regularExpression)
        }
        let rest = html[open.upperBound...]
        let close = rest.range(of: "</body>", options: .caseInsensitive)?.lowerBound ?? rest.endIndex
        return String(rest[..<close])
    }

    /// 임시 보관함의 초안을 이어서 쓰는 시작 값 (S-022). 받는 사람, 제목, 본문, 첨부를 그대로 옮긴다.
    public static func resume(draft m: MailMessage, bodyHTML: String) -> ComposeDraft {
        var d = ComposeDraft(kind: .new)
        func list(_ r: [Recipient]?) -> String { AddressParser.format((r ?? []).compactMap { $0.emailAddress.mailAddress }) }
        d.to = list(m.toRecipients)
        d.cc = list(m.ccRecipients)
        d.bcc = list(m.bccRecipients)
        d.subject = m.subject ?? ""
        d.bodyHTML = extractBody(bodyHTML)
        d.draftMessageID = m.id
        d.forwardAttachmentsFrom = (m.hasAttachments ?? false) ? m.id : nil
        // 답장 초안이면 저장된 References로 스레드를 잇는다.
        if !m.referenceIDs.isEmpty {
            d.references = m.referenceIDs
            d.inReplyTo = m.referenceIDs.last
        }
        return d
    }

    /// 원본 메시지에서 작성 창 시작 값을 만든다.
    public static func draft(kind: ComposeKind, message m: MailMessage, bodyHTML: String,
                             myAddress: String?, timeZone: TimeZone = .current) -> ComposeDraft {
        var d = ComposeDraft(kind: kind)
        d.subject = subject(for: kind, original: m.subject ?? "")
        let r = recipients(for: kind, message: m, myAddress: myAddress)
        d.to = AddressParser.format(r.to)
        d.cc = AddressParser.format(r.cc)
        d.quoteHTML = quoteHTML(for: kind, message: m, bodyHTML: bodyHTML, timeZone: timeZone)
        if kind == .forward {
            d.forwardAttachmentsFrom = (m.hasAttachments ?? false) ? m.id : nil
        } else if let id = m.internetMessageId, !id.isEmpty {
            d.inReplyTo = id
            var refs = m.referenceIDs
            if !refs.contains(id) { refs.append(id) }
            d.references = refs
        }
        return d
    }
}
