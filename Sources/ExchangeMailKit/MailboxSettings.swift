import Foundation

// MARK: 규칙 (S-039)

/// Graph messageRule (받은 편지함 서버 규칙). 앱이 만드는 조건·동작만 다루고, 나머지는 그대로 보여 준다.
public struct MessageRule: Codable, Identifiable, Hashable, Sendable {
    public struct Conditions: Codable, Hashable, Sendable {
        public var senderContains: [String]?
        public var subjectContains: [String]?
        public init(senderContains: [String]? = nil, subjectContains: [String]? = nil) {
            self.senderContains = senderContains
            self.subjectContains = subjectContains
        }
    }

    public struct Actions: Codable, Hashable, Sendable {
        public var moveToFolder: String?
        public var markAsRead: Bool?
        /// low, normal, high
        public var markImportance: String?
        public var delete: Bool?
        public var assignCategories: [String]?
        public var stopProcessingRules: Bool?
        public init(moveToFolder: String? = nil, markAsRead: Bool? = nil, markImportance: String? = nil,
                    delete: Bool? = nil, assignCategories: [String]? = nil, stopProcessingRules: Bool? = nil) {
            self.moveToFolder = moveToFolder
            self.markAsRead = markAsRead
            self.markImportance = markImportance
            self.delete = delete
            self.assignCategories = assignCategories
            self.stopProcessingRules = stopProcessingRules
        }
    }

    public var id: String
    public var displayName: String
    public var sequence: Int?
    public var isEnabled: Bool?
    public var conditions: Conditions?
    public var actions: Actions?

    public init(id: String = "", displayName: String, sequence: Int? = nil, isEnabled: Bool? = true,
                conditions: Conditions?, actions: Actions?) {
        self.id = id
        self.displayName = displayName
        self.sequence = sequence
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.actions = actions
    }

    /// 만들기 요청 본문: id는 서버가 정하므로 뺀다.
    public var createBody: [String: Any] {
        var body: [String: Any] = ["displayName": displayName, "sequence": sequence ?? 1, "isEnabled": isEnabled ?? true]
        var c: [String: Any] = [:]
        if let s = conditions?.senderContains, !s.isEmpty { c["senderContains"] = s }
        if let s = conditions?.subjectContains, !s.isEmpty { c["subjectContains"] = s }
        body["conditions"] = c
        var a: [String: Any] = ["stopProcessingRules": actions?.stopProcessingRules ?? true]
        if let f = actions?.moveToFolder { a["moveToFolder"] = f }
        if actions?.markAsRead == true { a["markAsRead"] = true }
        if let i = actions?.markImportance { a["markImportance"] = i }
        if actions?.delete == true { a["delete"] = true }
        if let c = actions?.assignCategories, !c.isEmpty { a["assignCategories"] = c }
        body["actions"] = a
        return body
    }

    /// 목록에 보일 한 줄 설명: "보낸 사람에 'x' 포함 → 프로젝트로 이동"
    public func summary(folderName: (String) -> String?) -> String {
        var parts: [String] = []
        if let s = conditions?.senderContains, !s.isEmpty { parts.append(L("보낸 사람에 '\(s.joined(separator: "', '"))' 포함")) }
        if let s = conditions?.subjectContains, !s.isEmpty { parts.append(L("제목에 '\(s.joined(separator: "', '"))' 포함")) }
        let when = parts.isEmpty ? L("모든 메일") : parts.joined(separator: L(" 또는 "))
        var does: [String] = []
        if let f = actions?.moveToFolder { does.append(L("\(folderName(f) ?? L("다른 폴더"))로 이동")) }
        if actions?.markAsRead == true { does.append(L("읽음으로 표시")) }
        if actions?.markImportance == "high" { does.append(L("중요도 높음")) }
        if actions?.delete == true { does.append(L("지우기")) }
        if let c = actions?.assignCategories, !c.isEmpty { does.append(L("범주 '\(c.joined(separator: "', '"))'")) }
        return "\(when) → \(does.isEmpty ? L("(Outlook에서 만든 동작)") : does.joined(separator: ", "))"
    }
}

/// 설정 화면에서 만드는 간단한 규칙
public struct RuleDraft: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable { case sender, subject }
    public enum Action: Equatable, Sendable {
        case move(folderID: String)
        case markRead
        case importanceHigh
        case delete
    }

    public var name: String
    public var field: Field
    public var text: String
    public var action: Action

    public init(name: String, field: Field, text: String, action: Action) {
        self.name = name
        self.field = field
        self.text = text
        self.action = action
    }

    /// 쉼표로 여러 단어를 넣을 수 있다 ("견적, 발주").
    public var words: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var isValid: Bool { !words.isEmpty }

    public func rule(sequence: Int) -> MessageRule {
        let conditions = field == .sender
            ? MessageRule.Conditions(senderContains: words)
            : MessageRule.Conditions(subjectContains: words)
        let actions: MessageRule.Actions = switch action {
        case .move(let folderID): .init(moveToFolder: folderID, stopProcessingRules: true)
        case .markRead: .init(markAsRead: true, stopProcessingRules: false)
        case .importanceHigh: .init(markImportance: "high", stopProcessingRules: false)
        case .delete: .init(delete: true, stopProcessingRules: true)
        }
        let title = name.trimmingCharacters(in: .whitespaces)
        return MessageRule(displayName: title.isEmpty ? words.joined(separator: ", ") : title,
                           sequence: sequence, isEnabled: true, conditions: conditions, actions: actions)
    }
}

// MARK: 부재중 자동 응답 (S-040)

/// Graph automaticRepliesSetting
public struct AutomaticReplies: Codable, Equatable, Sendable {
    /// disabled, alwaysEnabled, scheduled
    public var status: String
    /// none, contactsOnly, all
    public var externalAudience: String?
    public var scheduledStartDateTime: GraphDateTime?
    public var scheduledEndDateTime: GraphDateTime?
    public var internalReplyMessage: String?
    public var externalReplyMessage: String?

    public init(status: String = "disabled", externalAudience: String? = "none",
                scheduledStartDateTime: GraphDateTime? = nil, scheduledEndDateTime: GraphDateTime? = nil,
                internalReplyMessage: String? = "", externalReplyMessage: String? = "") {
        self.status = status
        self.externalAudience = externalAudience
        self.scheduledStartDateTime = scheduledStartDateTime
        self.scheduledEndDateTime = scheduledEndDateTime
        self.internalReplyMessage = internalReplyMessage
        self.externalReplyMessage = externalReplyMessage
    }

    public var isOn: Bool { status != "disabled" }

    /// 화면의 값으로 만든다. 기간이 있으면 scheduled, 없으면 alwaysEnabled. 글은 HTML로(줄바꿈 → <br>).
    public static func make(on: Bool, start: Date?, end: Date?, audience: String,
                            internalText: String, externalText: String) -> AutomaticReplies {
        func html(_ text: String) -> String {
            HTMLProcessor.escape(text).replacingOccurrences(of: "\n", with: "<br>")
        }
        func utc(_ d: Date) -> GraphDateTime {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return GraphDateTime(dateTime: f.string(from: d), timeZone: "UTC")
        }
        let scheduled = on && start != nil && end != nil
        return AutomaticReplies(status: !on ? "disabled" : (scheduled ? "scheduled" : "alwaysEnabled"),
                                externalAudience: audience,
                                scheduledStartDateTime: scheduled ? start.map(utc) : nil,
                                scheduledEndDateTime: scheduled ? end.map(utc) : nil,
                                internalReplyMessage: html(internalText),
                                externalReplyMessage: html(externalText))
    }

    /// 서버의 HTML 글을 입력 칸에 넣을 평문으로
    public static func plain(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        return HTMLProcessor.plainText(from: html)
    }
}

// MARK: 차단된 보낸 사람 (설정 > 정크 메일)

/// Graph v1.0에는 차단 목록 API가 없어 받은 편지함 서버 규칙 하나로 둔다. 앱이 꺼져 있어도 Exchange가 적용한다.
public enum BlockedSenders {
    public static let ruleName = "FAKUKU 차단된 보낸 사람"  // l10n: data
    public static let category = "차단됨"  // l10n: data

    public enum Mode: String, CaseIterable, Sendable {
        /// 지운 편지함으로 이동
        case trash
        /// 받은 편지함에 두고 "차단됨" 범주를 붙인다
        case keep
    }

    public static func isBlockRule(_ rule: MessageRule) -> Bool { rule.displayName == ruleName }

    public static func addresses(in rule: MessageRule?) -> [String] { rule?.conditions?.senderContains ?? [] }

    public static func mode(of rule: MessageRule?) -> Mode { rule?.actions?.delete == true ? .trash : .keep }

    /// 주소 목록으로 규칙을 만든다. 같은 주소(대소문자 무시)는 한 번만.
    public static func rule(addresses: [String], mode: Mode, enabled: Bool) -> MessageRule {
        var seen = Set<String>()
        let list = addresses.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let actions: MessageRule.Actions = mode == .trash
            ? .init(delete: true, stopProcessingRules: true)
            : .init(assignCategories: [category], stopProcessingRules: false)
        return MessageRule(displayName: ruleName, sequence: 1, isEnabled: enabled,
                           conditions: .init(senderContains: list), actions: actions)
    }
}
