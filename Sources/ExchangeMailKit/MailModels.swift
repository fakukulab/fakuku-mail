import Foundation

/// Graph 목록 응답: `{ "value": [...], "@odata.nextLink": "..." }`
public struct GraphList<T: Decodable & Sendable>: Decodable, Sendable {
    public let value: [T]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct MailFolder: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public var unreadItemCount: Int?
    public var totalItemCount: Int?
    /// Graph의 잘 알려진 폴더 이름 (inbox, drafts, sentitems, archive, junkemail, deleteditems). 서비스가 채운다.
    public var wellKnownName: String? = nil

    // wellKnownName은 Graph JSON에는 없지만(없으면 nil) 오프라인 캐시에는 저장한다 (S-026).
    enum CodingKeys: String, CodingKey { case id, displayName, unreadItemCount, totalItemCount, wellKnownName }

    public init(id: String, displayName: String, unreadItemCount: Int? = nil, totalItemCount: Int? = nil,
                wellKnownName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.unreadItemCount = unreadItemCount
        self.totalItemCount = totalItemCount
        self.wellKnownName = wellKnownName
    }

    /// 잘 알려진 이름, 없으면 표시 이름(영어·한국어)으로 추측한 이름.
    public var kind: String? { wellKnownName ?? FolderOrder.wellKnownName(forDisplayName: displayName) }

    /// 맥 Mail과 같은 SF Symbol.
    public var symbol: String {
        switch kind {
        case "inbox": "tray"
        case "drafts": "doc"
        case "sentitems": "paperplane"
        case "deleteditems": "trash"
        case "junkemail": "xmark.bin"
        case "archive": "archivebox"
        case "outbox": "tray.and.arrow.up"
        default: "folder"
        }
    }
}

public enum FolderOrder {
    public static let wellKnown = ["inbox", "drafts", "sentitems", "archive", "junkemail", "deleteditems", "outbox"]

    static let displayNames: [String: String] = [
        "inbox": "inbox", "받은 편지함": "inbox",
        "drafts": "drafts", "임시 보관함": "drafts",
        "sent items": "sentitems", "보낸 편지함": "sentitems", "보낸 항목": "sentitems",
        "archive": "archive", "보관": "archive", "보관 파일": "archive",
        "junk email": "junkemail", "정크 메일": "junkemail", "스팸 메일함": "junkemail",
        "deleted items": "deleteditems", "지운 편지함": "deleteditems", "지운 항목": "deleteditems",
        "outbox": "outbox", "보낼 편지함": "outbox",
    ]

    public static func wellKnownName(forDisplayName name: String) -> String? {
        displayNames[name.lowercased()]
    }

    /// 잘 알려진 폴더를 먼저, 나머지는 이름순.
    public static func sorted(_ folders: [MailFolder]) -> [MailFolder] {
        folders.sorted { a, b in
            let ia = a.kind.flatMap { wellKnown.firstIndex(of: $0) } ?? wellKnown.count
            let ib = b.kind.flatMap { wellKnown.firstIndex(of: $0) } ?? wellKnown.count
            return ia == ib ? a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending : ia < ib
        }
    }
}

public struct EmailAddress: Codable, Hashable, Sendable {
    public let name: String?
    public let address: String?

    public init(name: String?, address: String?) {
        self.name = name
        self.address = address
    }

    public var display: String {
        if let name, !name.isEmpty { name } else { address ?? "" }
    }

    public var mailAddress: MailAddress? {
        address.map { MailAddress(name: name, address: $0) }
    }
}

public struct Recipient: Codable, Hashable, Sendable {
    public let emailAddress: EmailAddress

    public init(name: String?, address: String?) {
        emailAddress = EmailAddress(name: name, address: address)
    }
}

public struct InternetHeader: Codable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct MailMessage: Codable, Identifiable, Hashable, Sendable {
    public struct Body: Codable, Hashable, Sendable {
        public let contentType: String
        public let content: String

        public init(contentType: String, content: String) {
            self.contentType = contentType
            self.content = content
        }

        public var isHTML: Bool { contentType.lowercased() == "html" }
    }

    public let id: String
    public var internetMessageId: String?
    public var conversationId: String?
    public var subject: String?
    public var from: Recipient?
    public var toRecipients: [Recipient]?
    public var ccRecipients: [Recipient]?
    public var bccRecipients: [Recipient]?
    /// 메일이 있는 폴더 id (대화 보기에서 다른 폴더 메일에 꼬리표를 붙인다)
    public var parentFolderId: String?
    public var receivedDateTime: Date?
    public var bodyPreview: String?
    public var isRead: Bool?
    public var hasAttachments: Bool?
    public var body: Body?
    /// 답장 스레드용 References 헤더를 읽으려고 요청하는 헤더 (상세 조회 때만).
    public var internetMessageHeaders: [InternetHeader]?

    public init(id: String, internetMessageId: String? = nil, conversationId: String? = nil, subject: String?,
                from: Recipient?, toRecipients: [Recipient]? = nil, ccRecipients: [Recipient]? = nil,
                receivedDateTime: Date?, bodyPreview: String? = nil, isRead: Bool? = true,
                hasAttachments: Bool? = false, body: Body? = nil, internetMessageHeaders: [InternetHeader]? = nil) {
        self.id = id
        self.internetMessageId = internetMessageId
        self.conversationId = conversationId
        self.subject = subject
        self.from = from
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.bccRecipients = nil
        self.parentFolderId = nil
        self.receivedDateTime = receivedDateTime
        self.bodyPreview = bodyPreview
        self.isRead = isRead
        self.hasAttachments = hasAttachments
        self.body = body
        self.internetMessageHeaders = internetMessageHeaders
    }

    public var title: String {
        if let subject, !subject.trimmingCharacters(in: .whitespaces).isEmpty { subject } else { "(제목 없음)" }
    }

    public var isUnread: Bool { isRead == false }

    /// 원본의 References 헤더 값들.
    public var referenceIDs: [String] {
        guard let raw = internetMessageHeaders?.first(where: { $0.name.lowercased() == "references" })?.value else { return [] }
        return raw.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.hasPrefix("<") }
    }
}

public struct FileAttachment: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public var contentType: String?
    public var size: Int?
    public var isInline: Bool?
    public var contentId: String?
    public var contentBytes: String?
    /// `#microsoft.graph.fileAttachment`, `itemAttachment`, `referenceAttachment`
    public var odataType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, contentType, size, isInline, contentId, contentBytes
        case odataType = "@odata.type"
    }

    public init(id: String, name: String, contentType: String?, size: Int?, isInline: Bool?,
                contentId: String? = nil, contentBytes: String?, odataType: String? = "#microsoft.graph.fileAttachment") {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.size = size
        self.isInline = isInline
        self.contentId = contentId
        self.contentBytes = contentBytes
        self.odataType = odataType
    }

    public var data: Data? { contentBytes.flatMap { Data(base64Encoded: $0) } }

    /// 본문 안 그림이 아닌, 목록에 보여 줄 첨부인지.
    public var isListed: Bool { !(isInline ?? false) }

    /// 파일로 저장하거나 전달할 수 있는지 (항목·참조 첨부는 내용이 없다).
    public var isFile: Bool { (odataType ?? "").hasSuffix("fileAttachment") && contentBytes != nil }

    /// 크기 표시: "12 KB"
    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(size ?? 0), countStyle: .file)
    }
}

/// Graph JSON 디코더. 날짜는 ISO 8601이고, 소수 초가 7자리까지 올 수 있다.
public enum GraphJSON {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "날짜 형식: \(s)"))
        }
        return d
    }

    public static func parseDate(_ s: String) -> Date? {
        if let x = try? Date(s, strategy: Date.ISO8601FormatStyle()) { return x }
        // 소수 초는 버린다: "2024-05-01T10:00:00.1234567Z" → "2024-05-01T10:00:00Z"
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if let x = try? Date(trimmed, strategy: Date.ISO8601FormatStyle()) { return x }
        // 시간대 없는 값은 UTC로 본다.
        return try? Date(trimmed + "Z", strategy: Date.ISO8601FormatStyle())
    }
}
