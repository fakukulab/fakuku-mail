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
    /// 하위 폴더 (S-031)
    public var parentFolderId: String? = nil
    public var childFolderCount: Int? = nil
    /// 사이드바 들여쓰기 깊이. `FolderOrder.tree`가 채운다.
    public var depth: Int? = nil

    // wellKnownName은 Graph JSON에는 없지만(없으면 nil) 오프라인 캐시에는 저장한다 (S-026).
    enum CodingKeys: String, CodingKey {
        case id, displayName, unreadItemCount, totalItemCount, wellKnownName, parentFolderId, childFolderCount, depth
    }

    public init(id: String, displayName: String, unreadItemCount: Int? = nil, totalItemCount: Int? = nil,
                wellKnownName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.unreadItemCount = unreadItemCount
        self.totalItemCount = totalItemCount
        self.wellKnownName = wellKnownName
    }

    /// 잘 알려진 이름, 없으면 표시 이름(영어·한국어)으로 추측한 이름. 하위 폴더는 이름이 같아도 잘 알려진 폴더가 아니다.
    public var kind: String? {
        wellKnownName ?? ((depth ?? 0) == 0 ? FolderOrder.wellKnownName(forDisplayName: displayName) : nil)
    }

    /// 이름 바꾸기·지우기를 할 수 있는 폴더 (잘 알려진 폴더는 안 된다)
    public var isEditable: Bool { kind == nil }

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
    /// 사이드바의 "깃발 표시" (서버 폴더가 아니다, S-029)
    public static let flaggedID = "__flagged"

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

    /// 사이드바 순서 (S-031): 맨 위 폴더는 `sorted` 순서, 하위 폴더는 부모 바로 아래에 이름순으로, 깊이를 채운다.
    public static func tree(_ folders: [MailFolder]) -> [MailFolder] {
        let ids = Set(folders.map(\.id))
        var children: [String: [MailFolder]] = [:]
        var roots: [MailFolder] = []
        for f in folders {
            if let parent = f.parentFolderId, ids.contains(parent) {
                children[parent, default: []].append(f)
            } else {
                var root = f
                root.depth = 0
                roots.append(root)
            }
        }
        var out: [MailFolder] = []
        func visit(_ f: MailFolder, depth: Int) {
            var copy = f
            copy.depth = depth
            out.append(copy)
            guard depth < 8 else { return }
            for child in (children[f.id] ?? []).sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
                visit(child, depth: depth + 1)
            }
        }
        for root in sorted(roots) { visit(root, depth: 0) }
        return out
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

    public var id: String
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
    /// 깃발 (S-029)
    public var flag: FollowupFlag?
    /// `#microsoft.graph.eventMessageRequest`면 회의 초대 (S-038)
    public var odataType: String?
    /// 회의 초대 메일의 일정 (`$expand=microsoft.graph.eventMessage/event`로 받는다)
    public var event: MailEvent?
    /// low, normal, high (S-041, S-042)
    public var importance: String?
    /// Outlook 범주 이름 (S-041)
    public var categories: [String]?
    /// MAPI 확장 속성. 목록은 마지막 동작(답장·전달, `Integer 0x1081`)만 받는다 (S-090)
    public var singleValueExtendedProperties: [ExtendedProperty]?

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
        self.flag = nil
        self.odataType = nil
        self.event = nil
        self.importance = nil
        self.categories = nil
        self.singleValueExtendedProperties = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, internetMessageId, conversationId, subject, from, toRecipients, ccRecipients, bccRecipients
        case parentFolderId, receivedDateTime, bodyPreview, isRead, hasAttachments, body, internetMessageHeaders, flag, event
        case importance, categories, singleValueExtendedProperties
        case odataType = "@odata.type"
    }

    /// 회의 초대(수락·거절할 수 있는 것)
    public var isMeetingRequest: Bool { odataType?.hasSuffix("eventMessageRequest") ?? false }

    public var isFlagged: Bool { flag?.flagStatus == "flagged" }

    /// 이 메일에 마지막으로 한 일: 답장, 전체 답장, 전달 (S-090). Outlook·웹 메일에서 한 것도 보인다.
    public var replyState: ReplyState? {
        get {
            func value(_ tag: String) -> Int? {
                singleValueExtendedProperties?.first { $0.id.lowercased().hasSuffix(tag) }?.value.flatMap { Int($0) }
            }
            // 마지막 동작 값이 없으면 Outlook 아이콘 값으로 (이것만 남기는 메일 앱이 있다)
            return value(ReplyState.propertyTag).flatMap(ReplyState.init(verb:))
                ?? value(ReplyState.iconTag).flatMap(ReplyState.init(iconIndex:))
        }
        set {
            var props = (singleValueExtendedProperties ?? []).filter {
                let id = $0.id.lowercased()
                return !id.hasSuffix(ReplyState.propertyTag) && !id.hasSuffix(ReplyState.iconTag)
            }
            if let newValue { props.append(ExtendedProperty(id: ReplyState.propertyID, value: "\(newValue.verb)")) }
            singleValueExtendedProperties = props.isEmpty ? nil : props
        }
    }

    public var title: String {
        if let subject, !subject.trimmingCharacters(in: .whitespaces).isEmpty { subject } else { L("(제목 없음)") }
    }

    public var isUnread: Bool { isRead == false }

    /// 원본의 References 헤더 값들.
    public var referenceIDs: [String] {
        guard let raw = internetMessageHeaders?.first(where: { $0.name.lowercased() == "references" })?.value else { return [] }
        return raw.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.hasPrefix("<") }
    }
}

/// Graph singleValueLegacyExtendedProperty
public struct ExtendedProperty: Codable, Hashable, Sendable {
    public var id: String
    public var value: String?

    public init(id: String, value: String?) {
        self.id = id
        self.value = value
    }
}

/// 메일에 마지막으로 한 일 (MAPI PidTagLastVerbExecuted, 0x1081). Outlook과 같은 값을 쓴다.
public enum ReplyState: String, Codable, Hashable, Sendable {
    case replied, repliedAll, forwarded

    /// Graph 확장 속성 id
    public static let propertyID = "Integer 0x1081"  // l10n: data
    static let propertyTag = "0x1081"  // l10n: data
    static let iconTag = "0x1080"  // l10n: data
    /// 목록 요청에 붙이는 `$expand` (마지막 동작과 Outlook 아이콘 두 속성만)
    public static let listExpand =
        "singleValueExtendedProperties($filter=id eq 'Integer 0x1081' or id eq 'Integer 0x1080')"  // l10n: data

    /// MS-OXOMSG: 102 보낸 사람에게 답장, 103 전체 답장, 104 전달
    public init?(verb: Int) {
        switch verb {
        case 102: self = .replied
        case 103: self = .repliedAll
        case 104: self = .forwarded
        default: return nil
        }
    }

    public var verb: Int {
        switch self {
        case .replied: 102
        case .repliedAll: 103
        case .forwarded: 104
        }
    }

    /// Outlook 목록 아이콘 (PidTagIconIndex 0x1080): 261 답장함, 262 전달함
    public var iconIndex: Int { self == .forwarded ? 262 : 261 }

    /// 아이콘 값에서 (전체 답장은 답장과 같은 값이다)
    public init?(iconIndex: Int) {
        switch iconIndex {
        case 261: self = .replied
        case 262: self = .forwarded
        default: return nil
        }
    }

    public var systemImage: String {
        switch self {
        case .replied: "arrowshape.turn.up.left.fill"
        case .repliedAll: "arrowshape.turn.up.left.2.fill"
        case .forwarded: "arrowshape.turn.up.right.fill"
        }
    }

    public var label: String {
        switch self {
        case .replied: L("답장함")
        case .repliedAll: L("전체 답장함")
        case .forwarded: L("전달함")
        }
    }

    /// 보낸 작성 창 종류에서
    public init?(_ kind: ComposeKind) {
        switch kind {
        case .reply: self = .replied
        case .replyAll: self = .repliedAll
        case .forward: self = .forwarded
        default: return nil
        }
    }
}

/// Graph followupFlag. `flagStatus`: notFlagged, flagged, complete
public struct FollowupFlag: Codable, Hashable, Sendable {
    public var flagStatus: String?

    public init(flagStatus: String?) {
        self.flagStatus = flagStatus
    }

    public static let flagged = FollowupFlag(flagStatus: "flagged")
    public static let notFlagged = FollowupFlag(flagStatus: "notFlagged")
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
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "날짜 형식: \(s)"))  // l10n: data
        }
        return d
    }

    public static func parseDate(_ s: String) -> Date? {
        // 소수 초는 버린다: "2024-05-01T10:00:00.1234567Z" → "2024-05-01T10:00:00Z".
        // 먼저 뗀다: 새 macOS의 ISO8601FormatStyle은 소수 초도 읽어, 같은 메일의 시각이 기기마다 달라졌다.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if let x = try? Date(trimmed, strategy: Date.ISO8601FormatStyle()) { return x }
        // 시간대 없는 값은 UTC로 본다.
        return try? Date(trimmed + "Z", strategy: Date.ISO8601FormatStyle())
    }
}
