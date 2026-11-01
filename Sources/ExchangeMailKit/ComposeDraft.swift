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
    /// 전달할 때 첨부를 가져올 원본 메시지 id (Graph id)
    public var forwardAttachmentsFrom: String?

    public init(kind: ComposeKind = .new, to: String = "", subject: String = "") {
        self.kind = kind
        self.to = to
        self.subject = subject
    }
}

public enum ReplyBuilder {

    static let replyPrefixes = ["re:", "회신:", "답장:", "aw:", "sv:"]
    static let forwardPrefixes = ["fw:", "fwd:", "전달:", "wg:", "tr:"]

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
            var header = "<b>보낸 사람:</b> \(from)<br><b>날짜:</b> \(HTMLProcessor.escape(when))<br><b>받는 사람:</b> \(to)<br>"
            if !cc.isEmpty { header += "<b>참조:</b> \(cc)<br>" }
            header += "<b>제목:</b> \(HTMLProcessor.escape(m.title))"
            return """
            <div data-quote="forward"><br><div>-------- 전달된 메시지 --------</div>\
            <div style="font-size:12px">\(header)</div><br>\(body)</div>
            """
        }
        return """
        <div data-quote="reply"><br><div style="font-size:12px">\(HTMLProcessor.escape(when)), \(from) 님이 작성:</div>\
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
