import Foundation

// M24 IMAP (iCloud, Gmail, 그 밖의 IMAP 메일): 서버와 주고받는 글을 해석하는 순수 코드.
// 연결(TLS)과 명령 보내기는 앱(Mail/IMAPConnection.swift), 메일 서비스는 Mail/IMAPMailService.swift.
// RFC 3501(IMAP4rev1) 가운데 이 앱이 쓰는 것만: 응답 줄, 목록, 따옴표 글, {n} 덩어리, ENVELOPE, FLAGS, LIST.

/// 서버 응답 안의 값 하나
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    /// 따옴표 글이나 {n} 덩어리 (바이트 그대로)
    case string(Data)
    case list([IMAPValue])
    case nilValue

    /// 글자로 (덩어리는 UTF-8, 안 되면 ISO-8859-1)
    public var text: String? {
        switch self {
        case .atom(let a): a
        case .string(let d): String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
        default: nil
        }
    }

    public var int: Int? { text.flatMap { Int($0) } }
    public var items: [IMAPValue]? { if case .list(let l) = self { l } else { nil } }
    public var data: Data? {
        switch self {
        case .string(let d): d
        case .atom(let a): Data(a.utf8)
        default: nil
        }
    }
}

/// 서버 응답 하나
public enum IMAPResponse: Equatable, Sendable {
    /// "* ..." (값들)
    case untagged([IMAPValue])
    /// "A1 OK ..." / NO / BAD
    case tagged(tag: String, status: String, text: String)
    /// "+ ..." (서버가 더 보내라고 한다)
    case continuation(String)
}

public enum IMAP {

    // MARK: 응답 나누기

    /// 버퍼에서 완성된 응답 하나를 꺼낸다. 줄 끝이 {n}이면 n바이트 덩어리와 그 뒤 줄까지가 한 응답이다.
    /// 아직 다 오지 않았으면 nil.
    public static func nextResponse(in buffer: Data) -> (response: Data, rest: Data)? {
        guard case .complete(let end) = scan(buffer, from: 0) else { return nil }
        return (buffer.subdata(in: 0..<end), buffer.subdata(in: end..<buffer.count))
    }

    /// 버퍼 훑기 결과: 응답이 `end` 바로 앞에서 끝났다, 또는 버퍼가 `needed` 바이트가 될 때까지 기다려야 한다.
    public enum Scan: Equatable, Sendable {
        case complete(end: Int)
        case incomplete(needed: Int)
    }

    /// `start`(0부터 세는 위치)에서 시작하는 응답이 어디서 끝나는지. 복사 없이 훑는다 (큰 메일이 조각으로 와도
    /// 조각마다 버퍼 전체를 복사하지 않게). {n} 덩어리를 기다릴 때는 필요한 크기를 알려 그때까지 다시 훑지 않는다.
    public static func scan(_ buffer: Data, from start: Int) -> Scan {
        buffer.withUnsafeBytes { raw -> Scan in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = start
            while true {
                var lf = i
                while lf < n && b[lf] != 10 { lf += 1 }
                guard lf < n else { return .incomplete(needed: n + 1) }
                let lineEnd = lf > i && b[lf - 1] == 13 ? lf - 1 : lf
                if lineEnd > i, b[lineEnd - 1] == UInt8(ascii: "}") {
                    var open = lineEnd - 2
                    while open >= i && b[open] != UInt8(ascii: "{") { open -= 1 }
                    if open >= i {
                        var size = 0
                        var digits = 0
                        var k = open + 1
                        while k < lineEnd - 1 {
                            let c = b[k]
                            if c >= 48 && c <= 57 { size = size * 10 + Int(c - 48); digits += 1 } else if c != UInt8(ascii: "+") { digits = 0; break }
                            k += 1
                        }
                        if digits > 0 {
                            let literalEnd = lf + 1 + size
                            guard n >= literalEnd else { return .incomplete(needed: literalEnd) }
                            i = literalEnd
                            continue
                        }
                    }
                }
                return .complete(end: lf + 1)
            }
        }
    }

    /// 응답 하나를 해석한다.
    public static func parse(_ response: Data) -> IMAPResponse {
        var p = Parser(bytes: [UInt8](response))
        if p.peek == UInt8(ascii: "*") {
            p.i += 1
            p.skipSpaces()
            return .untagged(p.values())
        }
        if p.peek == UInt8(ascii: "+") {
            p.i += 1
            return .continuation(p.restOfLine())
        }
        let tag = p.word()
        p.skipSpaces()
        let status = p.word().uppercased()
        p.skipSpaces()
        return .tagged(tag: tag, status: status, text: p.restOfLine())
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func skipSpaces() { while peek == 32 { i += 1 } }

        mutating func word() -> String {
            let start = i
            while let c = peek, c != 32, c != 13, c != 10 { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func restOfLine() -> String {
            let start = i
            while let c = peek, c != 13, c != 10 { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        /// 줄 끝(또는 닫는 괄호)까지의 값들
        mutating func values(until close: UInt8? = nil) -> [IMAPValue] {
            var out: [IMAPValue] = []
            while let c = peek {
                if c == 32 { i += 1; continue }
                if c == 13 || c == 10 { if close == nil { break } else { i += 1; continue } }
                if let close, c == close { i += 1; break }
                out.append(value())
            }
            return out
        }

        mutating func value() -> IMAPValue {
            guard let c = peek else { return .nilValue }
            switch c {
            case UInt8(ascii: "("):
                i += 1
                return .list(values(until: UInt8(ascii: ")")))
            case UInt8(ascii: "\""):
                i += 1
                var out: [UInt8] = []
                while let ch = peek {
                    i += 1
                    if ch == UInt8(ascii: "\\"), let next = peek { out.append(next); i += 1; continue }
                    if ch == UInt8(ascii: "\"") { break }
                    out.append(ch)
                }
                return .string(Data(out))
            case UInt8(ascii: "{"):
                // {n}\r\n 뒤의 n바이트
                let start = i + 1
                while let ch = peek, ch != UInt8(ascii: "}") { i += 1 }
                let n = Int(String(decoding: bytes[start..<i].filter { $0 != UInt8(ascii: "+") }, as: UTF8.self)) ?? 0
                i += 1   // }
                if peek == 13 { i += 1 }
                if peek == 10 { i += 1 }
                let end = min(bytes.count, i + n)
                let data = Data(bytes[i..<end])
                i = end
                return .string(data)
            default:
                // 아톰: 공백·괄호·줄 끝까지. [ ]는 안쪽의 공백까지 아톰에 넣는다 (BODY[TEXT], [UIDVALIDITY 3]).
                let start = i
                var depth = 0
                while let ch = peek {
                    if ch == UInt8(ascii: "[") { depth += 1 }
                    if ch == UInt8(ascii: "]") { depth = max(0, depth - 1) }
                    if depth == 0 && (ch == 32 || ch == UInt8(ascii: "(") || ch == UInt8(ascii: ")")) { break }
                    if ch == 13 || ch == 10 { break }
                    i += 1
                }
                let word = String(decoding: bytes[start..<i], as: UTF8.self)
                return word.uppercased() == "NIL" ? .nilValue : .atom(word)
            }
        }
    }

    // MARK: 명령에 넣는 글

    /// "따옴표 글" (\ 와 " 는 앞에 \)
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: FETCH

    /// "* 12 FETCH (UID 345 FLAGS (\Seen) …)" → ["UID": …, "FLAGS": …] (이름은 대문자)
    public static func fetchItems(_ values: [IMAPValue]) -> [String: IMAPValue]? {
        guard values.count >= 3, values[1].text?.uppercased() == "FETCH", let items = values[2].items else { return nil }
        var out: [String: IMAPValue] = [:]
        var k = 0
        while k + 1 < items.count {
            if let key = items[k].text?.uppercased() { out[key] = items[k + 1] }
            k += 2
        }
        return out
    }

    /// FETCH 결과의 본문 덩어리 (BODY[] 또는 BODY[…])
    public static func bodySection(_ items: [String: IMAPValue]) -> Data? {
        // 원본 전체(BODY[])를 먼저: 같은 FETCH에 머리글 몇 줄(BODY[HEADER.FIELDS …])이 함께 올 수 있다
        (items["BODY[]"] ?? items.first { $0.key.hasPrefix("BODY[") && !$0.key.hasPrefix("BODY[HEADER.FIELDS") }?.value)?.data
    }

    /// FETCH 결과의 머리글 몇 줄 (BODY[HEADER.FIELDS (…)])
    public static func headerFields(_ items: [String: IMAPValue]) -> Data? {
        items.first { $0.key.hasPrefix("BODY[HEADER.FIELDS") }?.value.data
    }

    // MARK: 대화 (IMAP에는 대화 번호가 없다)

    /// 대화의 첫 메일 Message-ID: References의 첫 번째, 없으면 In-Reply-To, 그것도 없으면 자기 Message-ID.
    /// 답장은 References에 대화의 첫 메일부터 적으므로 같은 대화의 메일은 같은 값이 된다.
    public static func threadRoot(references: String?, inReplyTo: String?, messageID: String?) -> String? {
        func ids(_ s: String?) -> [String] {
            guard let s else { return [] }
            var out: [String] = []
            var rest = Substring(s)
            while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
                out.append(String(rest[open...close]))
                rest = rest[rest.index(after: close)...]
            }
            return out
        }
        let root = ids(references).first ?? ids(inReplyTo).first ?? ids(messageID).first
        return root?.lowercased()
    }

    /// 앱의 대화 id: "imapconv:<계정>:<첫 메일 Message-ID>"
    public static func conversationID(account: String, root: String) -> String {
        "imapconv:\(account):\(root)"
    }

    /// 대화 id → (계정, 첫 메일 Message-ID)
    public static func parseConversationID(_ id: String) -> (account: String, root: String)? {
        guard id.hasPrefix("imapconv:") else { return nil }
        let body = id.dropFirst(9)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        return (String(body[..<colon]), String(body[body.index(after: colon)...]))
    }

    /// "17-Jul-1996 02:44:25 -0700"
    public static func internalDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    // MARK: ENVELOPE

    public struct Envelope: Equatable, Sendable {
        public var date: Date?
        public var subject: String
        public var from: [MailAddress]
        public var to: [MailAddress]
        public var cc: [MailAddress]
        public var messageID: String?
    }

    /// ENVELOPE (date subject from sender reply-to to cc bcc in-reply-to message-id)
    public static func envelope(_ value: IMAPValue) -> Envelope? {
        guard let v = value.items, v.count >= 10 else { return nil }
        func text(_ x: IMAPValue) -> String { x.text.map(MailArchive.decodeWords) ?? "" }
        func addresses(_ x: IMAPValue) -> [MailAddress] {
            (x.items ?? []).compactMap { a in
                guard let p = a.items, p.count >= 4, let mailbox = p[2].text, let host = p[3].text else { return nil }
                let name = p[0].text.map(MailArchive.decodeWords)
                return MailAddress(name: name?.isEmpty == false ? name : nil, address: "\(mailbox)@\(host)")
            }
        }
        return Envelope(date: v[0].text.flatMap(MailArchive.parseDate), subject: text(v[1]),
                        from: addresses(v[2]), to: addresses(v[5]), cc: addresses(v[6]),
                        messageID: v[9].text)
    }

    /// FLAGS (\Seen \Flagged …) → 소문자 집합
    public static func flags(_ value: IMAPValue?) -> Set<String> {
        Set((value?.items ?? []).compactMap { $0.text?.lowercased() })
    }

    /// BODYSTRUCTURE에 첨부가 있는가 (disposition "attachment"나 이름 있는 비글자 부분)
    public static func hasAttachment(_ value: IMAPValue?) -> Bool {
        guard let value else { return false }
        func walk(_ v: IMAPValue) -> Bool {
            switch v {
            case .list(let items):
                return items.contains(where: walk)
            case .atom, .string:
                let t = v.text?.lowercased() ?? ""
                return t == "attachment"
            case .nilValue:
                return false
            }
        }
        return walk(value)
    }

    // MARK: LIST (폴더)

    public struct ListEntry: Equatable, Sendable {
        public var flags: Set<String>
        public var delimiter: String?
        /// 서버의 폴더 경로 (수정 UTF-7 그대로)
        public var path: String
    }

    /// "* LIST (\HasNoChildren \Sent) "/" "Sent Messages"" 의 값들
    public static func listEntry(_ values: [IMAPValue]) -> ListEntry? {
        guard values.count >= 4, ["LIST", "XLIST"].contains(values[0].text?.uppercased() ?? ""),
              let flags = values[1].items, let path = values[3].text else { return nil }
        return ListEntry(flags: Set(flags.compactMap { $0.text?.lowercased() }), delimiter: values[2].text, path: path)
    }

    /// 폴더 종류: 특수 용도 표시(RFC 6154) → 없으면 흔한 이름 (iCloud, Gmail, 한국어)
    public static func kind(of entry: ListEntry) -> String? {
        if entry.path.uppercased() == "INBOX" { return "inbox" }
        let f = entry.flags
        if f.contains("\\sent") { return "sentitems" }
        if f.contains("\\drafts") { return "drafts" }
        if f.contains("\\trash") { return "deleteditems" }
        if f.contains("\\junk") { return "junkemail" }
        if f.contains("\\archive") { return "archive" }
        if f.contains("\\all") { return "allmail" }
        let name = (entry.delimiter.map { entry.path.components(separatedBy: $0).last ?? entry.path } ?? entry.path).lowercased()
        switch name {
        case "sent messages", "sent", "sent mail", "sent items": return "sentitems"
        case "drafts", "draft": return "drafts"
        case "deleted messages", "trash", "deleted items", "bin": return "deleteditems"
        case "junk", "spam", "junk e-mail", "bulk mail": return "junkemail"
        case "archive", "archives": return "archive"
        default: return nil
        }
    }

    // MARK: 수정 UTF-7 (RFC 3501 5.1.3, 한글 폴더 이름)

    /// "&1VyuAA-" → "한글"
    public static func decodeFolderName(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let dash = after.firstIndex(of: "-") else { out += after; return out }
            let chunk = after[..<dash]
            if chunk.isEmpty {
                out += "&"
            } else {
                var b64 = chunk.replacingOccurrences(of: ",", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                if let data = Data(base64Encoded: b64) {
                    out += String(data: data, encoding: .utf16BigEndian) ?? String(chunk)
                } else {
                    out += chunk
                }
            }
            rest = after[after.index(after: dash)...]
        }
        return out + rest
    }

    /// "한글" → "&1VyuAA-"
    public static func encodeFolderName(_ s: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var data = Data()
            for u in pending { data.append(UInt8(u >> 8)); data.append(UInt8(u & 0xFF)) }
            out += "&" + data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: ",") + "-"
            pending = []
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending += Array(String(scalar).utf16)
            }
        }
        flush()
        return out
    }

    // MARK: 앱 안의 id (계정 + 폴더 경로 + UID)
    // 계정이 달라도 겹치지 않게 계정 id를 넣는다. 경로의 : # %는 %로 감싼다.

    public static func folderID(account: String, path: String) -> String {
        "imap:\(account):\(escape(path))"
    }

    public static func messageID(account: String, path: String, uid: Int) -> String {
        folderID(account: account, path: path) + "#\(uid)"
    }

    /// "imap:<계정>:<경로>[#uid]" → (계정, 경로, uid)
    public static func parseID(_ id: String) -> (account: String, path: String, uid: Int?)? {
        guard id.hasPrefix("imap:") else { return nil }
        let body = id.dropFirst(5)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let account = String(body[..<colon])
        var rest = String(body[body.index(after: colon)...])
        var uid: Int?
        if let hash = rest.lastIndex(of: "#"), let n = Int(rest[rest.index(after: hash)...]) {
            uid = n
            rest = String(rest[..<hash])
        }
        return (account, rest.removingPercentEncoding ?? rest, uid)
    }

    static func escape(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":#%")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}

// MARK: 앱의 메일 형식으로

extension IMAP {
    /// 목록에 쓰는 FETCH 항목 (본문 없이)
    public static let summaryItems = "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO)]"

    /// FETCH 결과 → 목록의 메일 (본문 없음)
    public static func summary(_ items: [String: IMAPValue], account: String, path: String) -> MailMessage? {
        guard let uid = items["UID"]?.int else { return nil }
        let env = items["ENVELOPE"].flatMap(envelope)
        let marks = flags(items["FLAGS"])
        func recipient(_ a: MailAddress) -> Recipient { Recipient(name: a.name, address: a.address) }
        var m = MailMessage(id: messageID(account: account, path: path, uid: uid),
                            internetMessageId: env?.messageID,
                            subject: env?.subject,
                            from: env?.from.first.map(recipient),
                            toRecipients: env?.to.map(recipient),
                            ccRecipients: env?.cc.map(recipient),
                            receivedDateTime: items["INTERNALDATE"]?.text.flatMap(internalDate) ?? env?.date,
                            isRead: marks.contains("\\seen"),
                            hasAttachments: hasAttachment(items["BODYSTRUCTURE"]))
        m.parentFolderId = folderID(account: account, path: path)
        // 대화 묶기: References·In-Reply-To로 대화의 첫 메일을 찾는다
        let head = headerFields(items).map { MailArchive.Part(MailArchive.latin1($0)) }
        if let root = threadRoot(references: head?.header("references"), inReplyTo: head?.header("in-reply-to"),
                                 messageID: env?.messageID) {
            m.conversationId = conversationID(account: account, root: root)
        }
        m.flag = marks.contains("\\flagged") ? .flagged : .notFlagged
        return m
    }

    /// 원본 MIME → 본문을 채운 메일과 첨부. 본문의 cid: 그림은 data: 주소로 넣는다.
    public static func detail(_ base: MailMessage, mime: Data) -> (message: MailMessage, attachments: [FileAttachment]) {
        let mail = MailArchive.parse(mime)
        var m = base
        if let html = MailArchive.inlineImages(mail) {
            m.body = .init(contentType: "html", content: html)
        } else {
            m.body = .init(contentType: "text", content: mail.text ?? "")
        }
        m.bodyPreview = MailArchive.preview(mail)
        if m.subject == nil || m.subject?.isEmpty == true { m.subject = mail.subject }
        // 답장 스레드에 쓰는 머리글 (Message-ID, References, In-Reply-To)
        let part = MailArchive.Part(MailArchive.latin1(mime.prefix(64 * 1024)))
        m.internetMessageHeaders = ["message-id", "references", "in-reply-to", "reply-to"].compactMap { name in
            part.header(name).map { InternetHeader(name: name.capitalized, value: $0) }
        }
        let files = mail.attachments.filter { !$0.isInline || $0.contentID == nil }.map { a in
            FileAttachment(id: "\(base.id)/\(a.id)", name: a.name, contentType: a.contentType, size: a.data.count,
                           isInline: false, contentId: a.contentID, contentBytes: a.data.base64EncodedString(),
                           odataType: "#microsoft.graph.fileAttachment")
        }
        m.hasAttachments = !files.isEmpty
        return (m, files)
    }
}

/// iCloud·Gmail·일반 IMAP 계정의 설정 (암호는 키체인에)
public struct IMAPAccountConfig: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable, Identifiable {
        case icloud, gmail, other
        public var id: String { rawValue }
    }

    public var provider: Provider
    public var email: String
    public var name: String
    public var username: String
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    /// true면 587에서 STARTTLS, false면 처음부터 TLS(465)
    public var smtpStartTLS: Bool

    public init(provider: Provider, email: String, name: String, username: String? = nil,
                imapHost: String, imapPort: Int = 993, smtpHost: String, smtpPort: Int, smtpStartTLS: Bool) {
        self.provider = provider
        self.email = email
        self.name = name
        self.username = username ?? email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpStartTLS = smtpStartTLS
    }

    /// iCloud 메일: imap.mail.me.com:993 (TLS), smtp.mail.me.com:587 (STARTTLS). 사용자 이름은 주소의 @ 앞 (iCloud 안내)
    public static func icloud(email: String, name: String) -> IMAPAccountConfig {
        let user = email.lowercased().hasSuffix("@icloud.com") || email.lowercased().hasSuffix("@me.com")
            || email.lowercased().hasSuffix("@mac.com") ? String(email.split(separator: "@").first ?? "") : email
        return IMAPAccountConfig(provider: .icloud, email: email, name: name, username: user,
                                 imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpStartTLS: true)
    }

    /// Gmail: imap.gmail.com:993, smtp.gmail.com:465 (TLS). 사용자 이름은 전체 주소.
    public static func gmail(email: String, name: String) -> IMAPAccountConfig {
        IMAPAccountConfig(provider: .gmail, email: email, name: name, imapHost: "imap.gmail.com",
                          smtpHost: "smtp.gmail.com", smtpPort: 465, smtpStartTLS: false)
    }

    public var providerName: String {
        switch provider {
        case .icloud: "iCloud"
        case .gmail: "Gmail"
        case .other: "IMAP"
        }
    }
}
