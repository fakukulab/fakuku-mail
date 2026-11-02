import Foundation

// MARK: 필터 (S-041)

public struct MailFilter: Equatable, Codable, Sendable {
    public enum Period: String, Codable, CaseIterable, Sendable {
        case today, week, month
        public var label: String {
            switch self {
            case .today: "오늘"
            case .week: "이번 주"
            case .month: "이번 달"
            }
        }
    }

    public var unread = false
    public var flagged = false
    public var hasAttachments = false
    public var mentionsMe = false
    public var highImportance = false
    public var toOrCcMe = false
    public var category: String?
    public var received: Period?

    public init() {}

    public var isActive: Bool { self != MailFilter() }

    /// 목록 위에 보일 짧은 설명들
    public var labels: [String] {
        var out: [String] = []
        if unread { out.append("읽지 않음") }
        if flagged { out.append("깃발") }
        if hasAttachments { out.append("첨부 파일 있음") }
        if mentionsMe { out.append("멘션(@)") }
        if highImportance { out.append("높은 우선순위") }
        if toOrCcMe { out.append("받는 사람·참조에 나") }
        if let category { out.append("범주: \(category)") }
        if let received { out.append("받은 날짜: \(received.label)") }
        return out
    }

    /// 기간의 시작 시각
    public func since(now: Date, calendar: Calendar) -> Date? {
        switch received {
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: calendar.dateInterval(of: .month, for: now)?.start
        case nil: nil
        }
    }

    /// 서버 `$filter` (and로 잇는다). 거를 것이 없으면 nil.
    public func graphFilter(now: Date = Date(), calendar: Calendar = .current) -> String? {
        var parts: [String] = []
        if let start = since(now: now, calendar: calendar) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = TimeZone(identifier: "UTC")
            parts.append("receivedDateTime ge \(f.string(from: start))")
        }
        if unread { parts.append("isRead eq false") }
        if flagged { parts.append("flag/flagStatus eq 'flagged'") }
        if hasAttachments { parts.append("hasAttachments eq true") }
        if highImportance { parts.append("importance eq 'high'") }
        if let category {
            parts.append("categories/any(c:c eq '\(category.replacingOccurrences(of: "'", with: "''"))')")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// 앱에서 거르는 부분: 멘션, 받는 사람·참조에 나. 서버 필터를 못 쓴 경우(검색 중, 데모)는 전부 여기서 건다.
    public func matches(_ m: MailMessage, me: MailAddress?, serverFiltered: Bool, now: Date = Date(),
                        calendar: Calendar = .current) -> Bool {
        if !serverFiltered {
            if unread && !m.isUnread { return false }
            if flagged && !m.isFlagged { return false }
            if hasAttachments && m.hasAttachments != true { return false }
            if highImportance && m.importance != "high" { return false }
            if let category, !(m.categories ?? []).contains(category) { return false }
            if let start = since(now: now, calendar: calendar), (m.receivedDateTime ?? .distantPast) < start { return false }
        }
        let myAddress = me?.address.lowercased() ?? ""
        if toOrCcMe {
            let people = (m.toRecipients ?? []) + (m.ccRecipients ?? [])
            if !people.contains(where: { $0.emailAddress.address?.lowercased() == myAddress }) { return false }
        }
        if mentionsMe {
            // Graph v1.0에는 멘션 필드가 없어 미리보기에서 "@이름"이나 "@아이디"를 찾는다.
            let preview = (m.bodyPreview ?? "").lowercased()
            var keys: [String] = []
            if let name = me?.name, !name.isEmpty { keys.append("@" + name.lowercased()) }
            if let local = myAddress.split(separator: "@").first, !local.isEmpty { keys.append("@" + local) }
            if !keys.contains(where: { preview.contains($0) }) { return false }
        }
        return true
    }
}

/// Outlook 범주 (`/me/outlook/masterCategories`). GraphList에 넣으려면 Sendable이어야 해서 Kit에 둔다:
/// 앱 타깃에서 만든 타입은 메인 액터에 묶인다.
public struct OutlookCategory: Decodable, Sendable {
    public let displayName: String
}

// MARK: 정렬 (S-042)

public struct MailSort: Equatable, Codable, Sendable {
    public enum Key: String, Codable, CaseIterable, Sendable {
        case date, sender, subject, attachments, flag, importance
        public var label: String {
            switch self {
            case .date: "받은 날짜"
            case .sender: "보낸 사람"
            case .subject: "제목"
            case .attachments: "첨부 파일"
            case .flag: "깃발 상태"
            case .importance: "중요도"
            }
        }
    }

    public var key: Key = .date
    /// 새로운 항목(또는 가나다 역순·있는 것) 먼저
    public var descending = true

    public init(key: Key = .date, descending: Bool = true) {
        self.key = key
        self.descending = descending
    }

    /// 날짜 오름차순이면 서버에 asc로 부탁한다.
    public var serverOldestFirst: Bool { key == .date && !descending }

    /// 불러온 메일을 정렬한다. 같은 값이면 최근 메일 먼저.
    public func apply(_ messages: [MailMessage]) -> [MailMessage] {
        guard key != .date else {
            return messages.sorted { a, b in
                let da = a.receivedDateTime ?? .distantPast, db = b.receivedDateTime ?? .distantPast
                return descending ? da > db : da < db
            }
        }
        return messages.enumerated().sorted { x, y in
            let c = compare(x.element, y.element)
            if c != .orderedSame { return descending ? c == .orderedDescending : c == .orderedAscending }
            let da = x.element.receivedDateTime ?? .distantPast, db = y.element.receivedDateTime ?? .distantPast
            return da != db ? da > db : x.offset < y.offset
        }.map(\.element)
    }

    func compare(_ a: MailMessage, _ b: MailMessage) -> ComparisonResult {
        func rank(_ m: MailMessage) -> Int {
            switch key {
            case .attachments: (m.hasAttachments ?? false) ? 1 : 0
            case .flag: m.isFlagged ? 1 : 0
            case .importance: ["low": 0, "normal": 1, "high": 2][m.importance ?? "normal"] ?? 1
            default: 0
            }
        }
        switch key {
        case .sender:
            return (a.from?.emailAddress.display ?? "").localizedStandardCompare(b.from?.emailAddress.display ?? "")
        case .subject:
            return a.title.localizedStandardCompare(b.title)
        case .date:
            return .orderedSame
        default:
            let ra = rank(a), rb = rank(b)
            return ra == rb ? .orderedSame : (ra < rb ? .orderedAscending : .orderedDescending)
        }
    }
}
