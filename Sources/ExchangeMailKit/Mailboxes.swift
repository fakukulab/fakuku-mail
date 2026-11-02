import Foundation

// MARK: VIP (S-045)

/// VIP 한 사람. 주소로 알아보고, 사이드바와 목록에는 사람이 정한 이름과 아이콘(SF Symbol)을 쓴다.
public struct VIP: Codable, Hashable, Identifiable, Sendable {
    public var address: String
    public var name: String
    public var symbol: String

    public var id: String { address.lowercased() }

    public init(address: String, name: String, symbol: String = VIP.defaultSymbol) {
        self.address = address.trimmingCharacters(in: .whitespaces)
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.symbol = symbol
    }

    public static let defaultSymbol = "star.fill"

    /// 사이드바·목록에 보일 이름: 비어 있으면 주소
    public var title: String { name.isEmpty ? address : name }

    public func isSender(of m: MailMessage) -> Bool {
        m.from?.emailAddress.address?.lowercased() == id
    }
}

/// VIP·스마트 메일상자 편집기에서 고르는 아이콘
public enum MailboxSymbols {
    public static let all = [
        "star.fill", "crown.fill", "heart.fill", "person.crop.circle.fill", "person.2.fill", "briefcase.fill",
        "building.2.fill", "house.fill", "bolt.fill", "bell.fill", "flag.fill", "bookmark.fill",
        "tag.fill", "paperclip", "doc.text.fill", "cart.fill", "airplane", "graduationcap.fill",
        "sparkles", "leaf.fill", "lightbulb.fill", "gearshape.fill", "tray.full.fill", "envelope.badge.fill",
    ]
}

// MARK: 스마트 메일상자 (S-046)

/// 조건으로 모든 폴더의 메일을 모아 보는 상자. 이 Mac에만 저장한다 (Exchange에는 같은 기능이 없다).
public struct SmartMailbox: Codable, Hashable, Identifiable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case sender, subject, unread, flagged, attachments, highImportance, vip, receivedWithinDays, folder

        public var label: String {
            switch self {
            case .sender: L("보낸 사람에 포함")
            case .subject: L("제목에 포함")
            case .unread: L("읽지 않음")
            case .flagged: L("깃발 표시됨")
            case .attachments: L("첨부 파일 있음")
            case .highImportance: L("높은 우선순위")
            case .vip: L("VIP가 보냄")
            case .receivedWithinDays: L("최근 며칠 안에 받음")
            case .folder: L("폴더")
            }
        }

        /// 값을 입력해야 하는 조건 (글자, 일수, 폴더)
        public var needsValue: Bool { [.sender, .subject, .receivedWithinDays, .folder].contains(self) }
    }

    public struct Condition: Codable, Hashable, Identifiable, Sendable {
        public var id = UUID()
        public var field: Field
        /// 보낸 사람·제목은 찾을 글자, 기간은 일수, 폴더는 폴더 id
        public var value: String

        public init(field: Field, value: String = "") {
            self.field = field
            self.value = value
        }

        var text: String { value.trimmingCharacters(in: .whitespaces).lowercased() }
        var days: Int? { Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }

        /// 값이 필요한데 비어 있거나 틀렸으면 false
        public var isComplete: Bool {
            switch field {
            case .sender, .subject, .folder: !text.isEmpty
            case .receivedWithinDays: days != nil
            default: true
            }
        }

        func matches(_ m: MailMessage, vips: Set<String>, now: Date) -> Bool {
            switch field {
            case .sender:
                let from = [m.from?.emailAddress.name, m.from?.emailAddress.address].compactMap { $0?.lowercased() }
                return from.contains { $0.contains(text) }
            case .subject: return (m.subject ?? "").lowercased().contains(text)
            case .unread: return m.isUnread
            case .flagged: return m.isFlagged
            case .attachments: return m.hasAttachments == true
            case .highImportance: return m.importance == "high"
            case .vip: return vips.contains(m.from?.emailAddress.address?.lowercased() ?? "")
            case .receivedWithinDays:
                guard let days else { return false }
                return (m.receivedDateTime ?? .distantPast) >= now.addingTimeInterval(-Double(days) * 86_400)
            // Graph id는 대소문자를 가린다.
            case .folder: return m.parentFolderId == value.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    public var id: String
    public var name: String
    public var symbol: String
    /// true: 모든 조건, false: 하나라도
    public var matchAll: Bool
    public var conditions: [Condition]

    public init(id: String = SmartMailbox.newID(), name: String, symbol: String = "gearshape.fill", matchAll: Bool = true,
                conditions: [Condition]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.matchAll = matchAll
        self.conditions = conditions
    }

    public static func newID() -> String { VirtualMailbox.smartPrefix + UUID().uuidString }

    public var usable: [Condition] { conditions.filter(\.isComplete) }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !usable.isEmpty
    }

    /// 앱에서 거는 최종 판정. 조건이 없으면 아무것도 넣지 않는다.
    public func matches(_ m: MailMessage, vips: Set<String>, now: Date = Date()) -> Bool {
        let list = usable
        guard !list.isEmpty else { return false }
        return matchAll ? list.allSatisfy { $0.matches(m, vips: vips, now: now) }
                        : list.contains { $0.matches(m, vips: vips, now: now) }
    }

    /// "모두"일 때 한 폴더 조건이 있으면 그 폴더에서만 찾는다.
    public var serverFolderID: String? {
        guard matchAll else { return nil }
        let folders = usable.filter { $0.field == .folder }
        return folders.count == 1 ? folders[0].value.trimmingCharacters(in: .whitespaces) : nil
    }

    /// 서버 `$filter`로 미리 좁힐 수 있는 부분 ("모두"일 때만). 나머지는 `matches`가 앱에서 건다.
    public func graphFilter(now: Date = Date()) -> String? {
        guard matchAll else { return nil }
        var parts: [String] = []
        for c in usable {
            switch c.field {
            case .receivedWithinDays:
                if let days = c.days {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime]
                    f.timeZone = TimeZone(identifier: "UTC")
                    parts.insert("receivedDateTime ge \(f.string(from: now.addingTimeInterval(-Double(days) * 86_400)))", at: 0)
                }
            case .unread: parts.append("isRead eq false")
            case .flagged: parts.append("flag/flagStatus eq 'flagged'")
            case .attachments: parts.append("hasAttachments eq true")
            case .highImportance: parts.append("importance eq 'high'")
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// 사이드바 도움말에 보일 한 줄 설명
    public func summary(folderName: (String) -> String?) -> String {
        let parts = usable.map { c -> String in
            switch c.field {
            case .sender, .subject: "\(c.field.label) '\(c.value)'"
            case .receivedWithinDays: L("최근 \(c.value)일 안에 받음")
            case .folder: L("폴더: \(folderName(c.value) ?? c.value)")
            default: c.field.label
            }
        }
        return parts.joined(separator: matchAll ? L(" 그리고 ") : L(" 또는 "))
    }
}

/// 이 Mac에 저장하는 VIP와 스마트 메일상자 (`mailboxes.json`)
public struct LocalMailboxes: Codable, Equatable, Sendable {
    public var vips: [VIP] = []
    public var smart: [SmartMailbox] = []
    public init(vips: [VIP] = [], smart: [SmartMailbox] = []) {
        self.vips = vips
        self.smart = smart
    }
}

// MARK: 사이드바의 서버 폴더가 아닌 상자

public enum VirtualMailbox: Equatable, Sendable {
    case flagged
    /// 깃발 표시 > 색 하나 (이 Mac에만 저장한 깃발 색)
    case flagColor(FlagColor)
    case allVIPs
    case vip(address: String)
    case smart(id: String)

    public static let allVIPsID = "__vip"
    public static let flagColorPrefix = "__flag:"
    public static func id(for color: FlagColor) -> String { flagColorPrefix + color.rawValue }
    public static let vipPrefix = "vip:"
    public static let smartPrefix = "smart:"

    public init?(id: String) {
        if id == FolderOrder.flaggedID { self = .flagged }
        else if id.hasPrefix(Self.flagColorPrefix), let c = FlagColor(rawValue: String(id.dropFirst(Self.flagColorPrefix.count))) {
            self = .flagColor(c)
        }
        else if id == Self.allVIPsID { self = .allVIPs }
        else if id.hasPrefix(Self.vipPrefix) { self = .vip(address: String(id.dropFirst(Self.vipPrefix.count))) }
        else if id.hasPrefix(Self.smartPrefix) { self = .smart(id: id) }
        else { return nil }
    }

    public static func id(forVIP address: String) -> String { vipPrefix + address.lowercased() }

    /// 사이드바 id가 서버 폴더가 아니면 true (메일을 끌어다 놓을 수 없고, 검색은 모든 폴더에서 한다)
    public static func isVirtual(_ id: String?) -> Bool { id.flatMap { VirtualMailbox(id: $0) } != nil }
}

// MARK: 깃발 색 (맥 Mail처럼 일곱 가지)

/// Exchange 깃발에는 색이 없다 (Outlook은 범주로 색을 낸다). 색은 이 Mac에 메일마다 저장한다.
public enum FlagColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    public var label: String {
        switch self {
        case .red: L("빨간색")
        case .orange: L("주황색")
        case .yellow: L("노란색")
        case .green: L("초록색")
        case .blue: L("파란색")
        case .purple: L("보라색")
        case .gray: L("회색")
        }
    }

    /// 깃발은 있는데 색을 정한 적이 없을 때 (Outlook이나 다른 기기에서 단 깃발)
    public static let fallback = FlagColor.red

    /// 메일을 알아보는 열쇠: 옮겨도 바뀌지 않는 Internet Message-ID, 없으면 Graph id
    public static func key(for m: MailMessage) -> String {
        (m.internetMessageId?.isEmpty == false ? m.internetMessageId : nil) ?? m.id
    }
}
