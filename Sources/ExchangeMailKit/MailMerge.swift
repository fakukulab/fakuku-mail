import Foundation

// MARK: 개별 발송 (M18): 템플릿, 그룹, 자리표시자, 발송 간격

/// 여러 사람에게 같은 내용을 보내는 메일 틀. 본문은 HTML이고 `{{이름}}` 같은 자리표시자를 쓸 수 있다.
public struct MergeTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var subject: String
    public var html: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, subject: String = "", html: String = "<div><br></div>", updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.subject = subject
        self.html = html
        self.updatedAt = updatedAt
    }
}

/// 받는 사람 한 명. `fields`는 CSV의 나머지 열 (회사, 직함 등) → `{{회사}}`
public struct MergeMember: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var email: String
    public var fields: [String: String]

    public init(id: UUID = UUID(), name: String, email: String, fields: [String: String] = [:]) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.email = email.trimmingCharacters(in: .whitespaces)
        self.fields = fields
    }

    public var isValid: Bool { AddressParser.parse(email).valid.count == 1 && AddressParser.parse(email).invalid.isEmpty }
}

/// 받는 사람 그룹
public struct MergeGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [MergeMember]

    public init(id: UUID = UUID(), name: String, members: [MergeMember] = []) {
        self.id = id
        self.name = name
        self.members = members
    }

    /// 같은 주소는 한 번만 (대소문자 무시), 틀린 주소는 뺀다.
    public var sendable: [MergeMember] {
        var seen = Set<String>()
        return members.filter { $0.isValid && seen.insert($0.email.lowercased()).inserted }
    }

    /// 이 그룹에서 쓸 수 있는 자리표시자 이름 (이름, 이메일 + CSV 열)
    public var placeholders: [String] {
        var keys = ["이름", "이메일"]
        for m in members { for k in m.fields.keys.sorted() where !keys.contains(k) { keys.append(k) } }
        return keys
    }
}

/// `merge.json`에 저장하는 전체
public struct MergeLibrary: Codable, Equatable, Sendable {
    public var templates: [MergeTemplate] = []
    public var groups: [MergeGroup] = []
    public init(templates: [MergeTemplate] = [], groups: [MergeGroup] = []) {
        self.templates = templates
        self.groups = groups
    }
}

public enum MailMerge {
    /// `{{이름}}`, `{{name}}`, `{{이메일}}`, `{{email}}`, `{{회사}}` … 를 받는 사람 값으로 바꾼다.
    /// HTML이면 값을 이스케이프한다. 모르는 자리표시자는 빈칸으로.
    public static func render(_ text: String, for member: MergeMember, html: Bool) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let key = ns.substring(with: m.range(at: 1))
            let value = self.value(key, member)
            out += html ? HTMLProcessor.escape(value) : value
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func value(_ key: String, _ m: MergeMember) -> String {
        switch key.lowercased() {
        case "이름", "name", "성명": return m.name
        case "이메일", "email", "e-mail", "메일": return m.email
        default:
            if let v = m.fields[key] { return v }
            return m.fields.first { $0.key.lowercased() == key.lowercased() }?.value ?? ""
        }
    }

    /// 본문에 쓰인 자리표시자 이름들 (미리보기 경고용)
    public static func placeholders(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            if !out.contains(k) { out.append(k) }
        }
        return out
    }

    // MARK: CSV

    /// CSV를 받는 사람 목록으로 읽는다. 첫 줄은 머리글: 이름/name, 이메일/email 열을 찾고 나머지는 `fields`로.
    /// 쉼표·세미콜론·탭 구분, 따옴표 안의 쉼표와 줄바꿈, "" 이스케이프를 지원한다.
    public static func members(fromCSV text: String) -> (members: [MergeMember], skipped: Int) {
        // Swift는 "\r\n"을 한 글자로 본다. 엑셀·Windows CSV(CRLF)도 줄이 나뉘게 먼저 "\n"으로 바꾼다.
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rows = csvRows(normalized)
        guard let header = rows.first else { return ([], 0) }
        let keys = header.map { $0.trimmingCharacters(in: .whitespaces) }
        let lower = keys.map { $0.lowercased() }
        guard let emailCol = lower.firstIndex(where: { ["이메일", "email", "e-mail", "메일", "주소", "mail"].contains($0) }) else {
            return ([], max(rows.count - 1, 0))
        }
        let nameCol = lower.firstIndex { ["이름", "name", "성명", "full name"].contains($0) }
        var out: [MergeMember] = []
        var skipped = 0
        for row in rows.dropFirst() where !row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            guard emailCol < row.count else { skipped += 1; continue }
            var fields: [String: String] = [:]
            for (i, k) in keys.enumerated() where i != emailCol && i != nameCol && i < row.count && !k.isEmpty {
                fields[k] = row[i].trimmingCharacters(in: .whitespaces)
            }
            let m = MergeMember(name: nameCol.flatMap { $0 < row.count ? row[$0] : nil } ?? "", email: row[emailCol], fields: fields)
            if m.isValid { out.append(m) } else { skipped += 1 }
        }
        return (out, skipped)
    }

    static func csvRows(_ text: String) -> [[String]] {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let sep: Character = firstLine.contains("\t") ? "\t" : (firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ",")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        if chars.last != "\n" { chars.append("\n") }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

// MARK: 발송 간격 (스팸으로 보이지 않게)

/// 한꺼번에 보내지 않고 사람처럼 간격을 두고 보낸다.
/// Exchange Online 한도(분당 30통, 하루 받는 사람 10,000명)보다 훨씬 낮게 잡는다.
public struct SendPacing: Codable, Equatable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable {
        case careful, normal, fast
        public var label: String {
            switch self {
            case .careful: "신중하게 (60~120초 간격, 시간당 30통)"
            case .normal: "보통 (30~60초 간격, 시간당 60통)"
            case .fast: "빠르게 (10~20초 간격, 시간당 150통)"
            }
        }
        public var pacing: SendPacing {
            switch self {
            case .careful: SendPacing(minSeconds: 60, maxSeconds: 120, perHour: 30)
            case .normal: SendPacing(minSeconds: 30, maxSeconds: 60, perHour: 60)
            case .fast: SendPacing(minSeconds: 10, maxSeconds: 20, perHour: 150)
            }
        }
    }

    public var minSeconds: Double
    public var maxSeconds: Double
    /// 한 시간에 보낼 수 있는 최대 수. 넘으면 한 시간이 찰 때까지 쉰다.
    public var perHour: Int

    public init(minSeconds: Double, maxSeconds: Double, perHour: Int) {
        self.minSeconds = minSeconds
        self.maxSeconds = max(minSeconds, maxSeconds)
        self.perHour = max(1, perHour)
    }

    /// 다음 메일까지 기다릴 초: 간격 안의 무작위 값 (일정한 기계적 간격을 피한다)
    public func gap(random: Double) -> Double {
        minSeconds + (maxSeconds - minSeconds) * min(max(random, 0), 1)
    }

    /// 지난 한 시간에 보낸 시각들로 보면 지금부터 더 기다려야 하는 초 (한도 안이면 0)
    public func hourlyWait(sentAt times: [Date], now: Date) -> Double {
        let recent = times.filter { now.timeIntervalSince($0) < 3600 }.sorted()
        guard recent.count >= perHour, let oldest = recent.first else { return 0 }
        return max(0, 3600 - now.timeIntervalSince(oldest))
    }

    /// 대략 다 보내는 데 걸리는 시간(초)
    public func estimatedSeconds(count: Int) -> Double {
        guard count > 1 else { return 0 }
        let average = (minSeconds + maxSeconds) / 2
        let byGap = average * Double(count - 1)
        let byHour = Double((count - 1) / perHour) * 3600
        return max(byGap, byHour)
    }
}
