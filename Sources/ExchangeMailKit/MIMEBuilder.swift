import Foundation

public struct OutgoingAttachment: Equatable, Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct OutgoingMessage: Sendable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var html: String
    public var attachments: [OutgoingAttachment]
    /// 답장하는 원본의 Message-ID (`<...>` 포함 여부 상관없음).
    public var inReplyTo: String?
    /// 대화의 Message-ID 목록. 원본의 References + 원본 Message-ID.
    public var references: [String]

    public init(from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                subject: String, html: String, attachments: [OutgoingAttachment] = [],
                inReplyTo: String? = nil, references: [String] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.html = html
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }
}

/// 첨부 보정 설정. 작성 창에서 메일마다 바꿀 수 있다.
public struct FixOptions: Equatable, Sendable {
    /// 본문 이미지를 일반 첨부로 (서명과 인용문 안 이미지는 제외)
    public var imagesAsAttachments: Bool
    /// EUC-KR 파일명 (구형 국내 시스템)
    public var eucKRFilenames: Bool
    /// 이 크기(byte) 미만의 본문 이미지는 인라인으로 둔다
    public var minAttachmentBytes: Int

    public init(imagesAsAttachments: Bool = true, eucKRFilenames: Bool = false, minAttachmentBytes: Int = 0) {
        self.imagesAsAttachments = imagesAsAttachments
        self.eucKRFilenames = eucKRFilenames
        self.minAttachmentBytes = minAttachmentBytes
    }

    /// 작성 창의 "첨부 보정"을 끈 경우: 이미지는 인라인, 파일명은 표준 UTF-8 (NFC와 RFC 2231은 항상 적용).
    public static let off = FixOptions(imagesAsAttachments: false, eucKRFilenames: false, minAttachmentBytes: 0)
}

/// 보정이 적용된 RFC 5322 메시지를 만든다.
/// 구조: mixed( related( alternative(plain, html), 인라인 이미지… ), 첨부… ). 필요 없는 층은 생략한다.
public enum MIMEBuilder {

    /// Graph `sendMail`(MIME)은 요청 하나가 4MB를 넘으면 거절한다. 요청 본문은 MIME의 base64다.
    public static let graphRequestLimit = 4 * 1024 * 1024

    public static func graphRequestSize(forMIMEBytes count: Int) -> Int {
        (count + 2) / 3 * 4
    }

    static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func encodedWords(_ value: String) -> String {
        if FilenameEncoder.isASCIISafe(value) { return value }
        return FilenameEncoder.rfc2047Words(value).joined(separator: "\r\n ")
    }

    static func header(_ address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.address }
        if FilenameEncoder.isASCIISafe(name) && name.range(of: #"[(),.:;<>@\[\]]"#, options: .regularExpression) == nil {
            return "\(name) <\(address.address)>"
        }
        if FilenameEncoder.isASCIISafe(name) { return "\"\(name)\" <\(address.address)>" }
        return "\(encodedWords(name)) <\(address.address)>"
    }

    static func addressList(_ list: [MailAddress]) -> String {
        list.map(header).joined(separator: ",\r\n ")
    }

    /// `<id>` 형태로 맞춘다.
    static func angle(_ id: String) -> String {
        let t = id.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("<") ? t : "<\(t)>"
    }

    static func boundary(_ tag: String) -> String {
        "=_\(tag)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    public static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    public static func build(_ msg: OutgoingMessage, options: FixOptions = FixOptions(),
                             messageID: String? = nil, date: Date = Date()) -> Data {
        let processed = HTMLProcessor.process(html: msg.html,
                                              convertBodyImagesToAttachments: options.imagesAsAttachments,
                                              minInlineBytes: options.minAttachmentBytes)
        let inline = processed.images.filter { $0.contentID != nil }
        let moved = processed.images.filter { $0.contentID == nil }
            .map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        let attachments = msg.attachments + moved

        var h = "MIME-Version: 1.0\r\n"
        h += "Date: \(rfc5322Date(date))\r\n"
        h += "From: \(header(msg.from))\r\n"
        if !msg.to.isEmpty { h += "To: \(addressList(msg.to))\r\n" }
        if !msg.cc.isEmpty { h += "Cc: \(addressList(msg.cc))\r\n" }
        // Graph는 Bcc 헤더로 숨은 참조를 받고, 받는 사람에게는 이 헤더를 지워서 보낸다.
        if !msg.bcc.isEmpty { h += "Bcc: \(addressList(msg.bcc))\r\n" }
        h += "Subject: \(encodedWords(msg.subject))\r\n"
        if let id = messageID { h += "Message-ID: \(angle(id))\r\n" }
        if let r = msg.inReplyTo, !r.isEmpty { h += "In-Reply-To: \(angle(r))\r\n" }
        if !msg.references.isEmpty { h += "References: \(msg.references.map(angle).joined(separator: "\r\n "))\r\n" }

        // 본문 (alternative)
        let altB = boundary("alt")
        var alt = "--\(altB)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        alt += base64Lines(Data(HTMLProcessor.plainText(from: processed.html).utf8)) + "\r\n"
        alt += "--\(altB)\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        alt += base64Lines(Data(processed.html.utf8)) + "\r\n"
        alt += "--\(altB)--\r\n"
        let altPart = "Content-Type: multipart/alternative; boundary=\"\(altB)\"\r\n\r\n" + alt

        // related (인라인 이미지가 있을 때만)
        var bodyPart = altPart
        if !inline.isEmpty {
            let relB = boundary("rel")
            var rel = "--\(relB)\r\n" + altPart + "\r\n"
            for img in inline {
                rel += "--\(relB)\r\n"
                rel += "Content-Type: \(img.mimeType)\r\n"
                rel += "Content-Transfer-Encoding: base64\r\n"
                rel += "Content-ID: <\(img.contentID ?? "")>\r\n"
                rel += "Content-Disposition: inline;\r\n \(FilenameEncoder.parameter(key: "filename", filename: img.filename, eucKR: options.eucKRFilenames))\r\n\r\n"
                rel += base64Lines(img.data) + "\r\n"
            }
            rel += "--\(relB)--\r\n"
            bodyPart = "Content-Type: multipart/related; type=\"multipart/alternative\"; boundary=\"\(relB)\"\r\n\r\n" + rel
        }

        // mixed (첨부가 있을 때만)
        if attachments.isEmpty {
            return Data((h + bodyPart).utf8)
        }
        let mixB = boundary("mix")
        var mix = "--\(mixB)\r\n" + bodyPart + "\r\n"
        for a in attachments {
            let nameParam = FilenameEncoder.parameter(key: "name", filename: a.filename, eucKR: options.eucKRFilenames)
            let fileParam = FilenameEncoder.parameter(key: "filename", filename: a.filename, eucKR: options.eucKRFilenames)
            mix += "--\(mixB)\r\n"
            mix += "Content-Type: \(a.mimeType);\r\n \(nameParam)\r\n"
            mix += "Content-Transfer-Encoding: base64\r\n"
            mix += "Content-Disposition: attachment;\r\n \(fileParam)\r\n\r\n"
            mix += base64Lines(a.data) + "\r\n"
        }
        mix += "--\(mixB)--\r\n"
        return Data((h + "Content-Type: multipart/mixed; boundary=\"\(mixB)\"\r\n\r\n" + mix).utf8)
    }
}
