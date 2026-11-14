import Foundation

// MARK: 규칙 (S-039, S-075)

/// Graph messageRulePredicates. 규칙의 조건과 예외가 같은 꼴이다.
/// 조건: 종류가 다르면 모두 맞아야 하고(그리고), 한 종류 안의 여러 값은 하나만 맞으면 된다(또는).
/// 예외: 하나라도 맞으면 규칙을 건너뛴다.
public struct RulePredicates: Codable, Hashable, Sendable {
    /// 크기 범위 (KB)
    public struct SizeRange: Codable, Hashable, Sendable {
        public var minimumSize: Int?
        public var maximumSize: Int?
        public init(minimumSize: Int?, maximumSize: Int?) {
            self.minimumSize = minimumSize
            self.maximumSize = maximumSize
        }
    }

    public var bodyContains: [String]?
    public var bodyOrSubjectContains: [String]?
    public var categories: [String]?
    public var fromAddresses: [Recipient]?
    public var hasAttachments: Bool?
    public var headerContains: [String]?
    /// low, normal, high
    public var importance: String?
    public var isApprovalRequest: Bool?
    public var isAutomaticForward: Bool?
    public var isAutomaticReply: Bool?
    public var isEncrypted: Bool?
    public var isMeetingRequest: Bool?
    public var isMeetingResponse: Bool?
    public var isNonDeliveryReport: Bool?
    public var isPermissionControlled: Bool?
    public var isReadReceipt: Bool?
    public var isSigned: Bool?
    public var isVoicemail: Bool?
    /// any, call, doNotForward, followUp, fyi, forward, noResponseNecessary, read, reply, replyToAll, review
    public var messageActionFlag: String?
    public var notSentToMe: Bool?
    public var recipientContains: [String]?
    public var senderContains: [String]?
    /// normal, personal, private, confidential
    public var sensitivity: String?
    public var sentCcMe: Bool?
    public var sentOnlyToMe: Bool?
    public var sentToAddresses: [Recipient]?
    public var sentToMe: Bool?
    public var sentToOrCcMe: Bool?
    public var subjectContains: [String]?
    public var withinSizeRange: SizeRange?

    public init(senderContains: [String]? = nil, subjectContains: [String]? = nil) {
        self.senderContains = senderContains
        self.subjectContains = subjectContains
    }

    /// 빈 목록·false·빈 글자를 없는 값으로 바꾼다 (서버가 false나 []로 돌려줘도 조건이 아니다).
    public var cleaned: RulePredicates {
        func list<T>(_ a: [T]?) -> [T]? { a?.isEmpty == false ? a : nil }
        func on(_ b: Bool?) -> Bool? { b == true ? true : nil }
        func text(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
        var p = RulePredicates()
        p.bodyContains = list(bodyContains)
        p.bodyOrSubjectContains = list(bodyOrSubjectContains)
        p.categories = list(categories)
        p.fromAddresses = list(fromAddresses)
        p.hasAttachments = on(hasAttachments)
        p.headerContains = list(headerContains)
        p.importance = text(importance)
        p.isApprovalRequest = on(isApprovalRequest)
        p.isAutomaticForward = on(isAutomaticForward)
        p.isAutomaticReply = on(isAutomaticReply)
        p.isEncrypted = on(isEncrypted)
        p.isMeetingRequest = on(isMeetingRequest)
        p.isMeetingResponse = on(isMeetingResponse)
        p.isNonDeliveryReport = on(isNonDeliveryReport)
        p.isPermissionControlled = on(isPermissionControlled)
        p.isReadReceipt = on(isReadReceipt)
        p.isSigned = on(isSigned)
        p.isVoicemail = on(isVoicemail)
        p.messageActionFlag = text(messageActionFlag)
        p.notSentToMe = on(notSentToMe)
        p.recipientContains = list(recipientContains)
        p.senderContains = list(senderContains)
        p.sensitivity = text(sensitivity)
        p.sentCcMe = on(sentCcMe)
        p.sentOnlyToMe = on(sentOnlyToMe)
        p.sentToAddresses = list(sentToAddresses)
        p.sentToMe = on(sentToMe)
        p.sentToOrCcMe = on(sentToOrCcMe)
        p.subjectContains = list(subjectContains)
        p.withinSizeRange = withinSizeRange
        return p
    }

    public var isEmpty: Bool { cleaned == RulePredicates() }
}

/// Graph messageRule (받은 편지함 서버 규칙). Outlook에서 만든 규칙도 같은 꼴로 읽고 고친다.
public struct MessageRule: Codable, Identifiable, Hashable, Sendable {
    public typealias Conditions = RulePredicates

    public struct Actions: Codable, Hashable, Sendable {
        public var moveToFolder: String?
        public var copyToFolder: String?
        public var markAsRead: Bool?
        /// low, normal, high
        public var markImportance: String?
        /// 지운 편지함으로
        public var delete: Bool?
        public var permanentDelete: Bool?
        public var assignCategories: [String]?
        public var forwardTo: [Recipient]?
        public var forwardAsAttachmentTo: [Recipient]?
        public var redirectTo: [Recipient]?
        public var stopProcessingRules: Bool?

        public init(moveToFolder: String? = nil, copyToFolder: String? = nil, markAsRead: Bool? = nil,
                    markImportance: String? = nil, delete: Bool? = nil, permanentDelete: Bool? = nil,
                    assignCategories: [String]? = nil, forwardTo: [Recipient]? = nil,
                    forwardAsAttachmentTo: [Recipient]? = nil, redirectTo: [Recipient]? = nil,
                    stopProcessingRules: Bool? = nil) {
            self.moveToFolder = moveToFolder
            self.copyToFolder = copyToFolder
            self.markAsRead = markAsRead
            self.markImportance = markImportance
            self.delete = delete
            self.permanentDelete = permanentDelete
            self.assignCategories = assignCategories
            self.forwardTo = forwardTo
            self.forwardAsAttachmentTo = forwardAsAttachmentTo
            self.redirectTo = redirectTo
            self.stopProcessingRules = stopProcessingRules
        }

        /// 빈 값을 뺀 꼴. 다음 규칙 처리 안 함은 늘 적는다.
        public var cleaned: Actions {
            func list<T>(_ a: [T]?) -> [T]? { a?.isEmpty == false ? a : nil }
            func on(_ b: Bool?) -> Bool? { b == true ? true : nil }
            func text(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
            return Actions(moveToFolder: text(moveToFolder), copyToFolder: text(copyToFolder), markAsRead: on(markAsRead),
                           markImportance: text(markImportance), delete: on(delete), permanentDelete: on(permanentDelete),
                           assignCategories: list(assignCategories), forwardTo: list(forwardTo),
                           forwardAsAttachmentTo: list(forwardAsAttachmentTo), redirectTo: list(redirectTo),
                           stopProcessingRules: stopProcessingRules ?? false)
        }
    }

    public var id: String
    public var displayName: String
    public var sequence: Int?
    public var isEnabled: Bool?
    public var conditions: Conditions?
    public var exceptions: Conditions?
    public var actions: Actions?
    /// 서버가 이 규칙에 오류가 있다고 알린다 (지운 폴더로 옮기기 같은)
    public var hasError: Bool?
    /// 이 앱이나 Outlook 웹에서 고칠 수 없는 규칙 (Outlook 데스크톱 전용 규칙)
    public var isReadOnly: Bool?

    public init(id: String = "", displayName: String, sequence: Int? = nil, isEnabled: Bool? = true,
                conditions: Conditions?, exceptions: Conditions? = nil, actions: Actions?) {
        self.id = id
        self.displayName = displayName
        self.sequence = sequence
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.exceptions = exceptions
        self.actions = actions
    }

    /// 만들기 요청 본문: id·오류 표시는 서버가 정하므로 뺀다. 빈 조건은 보내지 않는다.
    public var createBody: [String: Any] {
        struct Body: Encodable {
            let displayName: String
            let sequence: Int
            let isEnabled: Bool
            let conditions: RulePredicates
            let exceptions: RulePredicates?
            let actions: Actions
        }
        var acts = (actions ?? Actions()).cleaned
        if actions?.stopProcessingRules == nil { acts.stopProcessingRules = true }
        let ex = exceptions?.cleaned
        let body = Body(displayName: displayName, sequence: sequence ?? 1, isEnabled: isEnabled ?? true,
                        conditions: (conditions ?? RulePredicates()).cleaned,
                        exceptions: ex?.isEmpty == false ? ex : nil, actions: acts)
        guard let data = try? JSONEncoder().encode(body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// 목록에 보일 한 줄 설명: "보낸 사람에 'x' 포함 → 프로젝트로 이동"
    public func summary(folderName: (String) -> String?) -> String {
        let form = RuleForm(rule: self)
        let when = form.conditions.isEmpty ? L("모든 메일") : form.conditions.map(\.summary).joined(separator: L(" 그리고 "))
        let does = form.actions.map { $0.summary(folderName: folderName) }
        var line = "\(when) → \(does.isEmpty ? L("(동작 없음)") : does.joined(separator: ", "))"
        if !form.exceptions.isEmpty {
            line += L(" (예외: \(form.exceptions.map(\.summary).joined(separator: L(" 또는 "))))")
        }
        return line
    }
}

// MARK: 규칙 편집 (S-075)

/// 조건·예외 한 줄의 종류. Outlook 규칙 창과 같은 목록 (Graph messageRulePredicates).
public enum RuleConditionKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    // 사람
    case from, sentTo, senderContains, recipientContains
    case sentToMe, sentOnlyToMe, sentCcMe, sentToOrCcMe, notSentToMe
    // 글
    case subjectContains, bodyContains, bodyOrSubjectContains, headerContains
    // 표시
    case importance, sensitivity, categories, messageActionFlag, hasAttachments, withinSizeRange
    // 메시지 종류
    case isMeetingRequest, isMeetingResponse, isAutomaticReply, isAutomaticForward, isReadReceipt
    case isNonDeliveryReport, isEncrypted, isSigned, isApprovalRequest, isVoicemail, isPermissionControlled

    public var id: String { rawValue }

    /// 줄에서 받는 값
    public enum Input: Sendable { case none, words, addresses, importance, sensitivity, flag, size }

    /// 추가 메뉴의 묶음
    public enum Group: String, CaseIterable, Sendable { case people, words, marked, type }

    public var input: Input {
        switch self {
        case .from, .sentTo: .addresses
        case .senderContains, .recipientContains, .subjectContains, .bodyContains, .bodyOrSubjectContains,
             .headerContains, .categories: .words
        case .importance: .importance
        case .sensitivity: .sensitivity
        case .messageActionFlag: .flag
        case .withinSizeRange: .size
        default: .none
        }
    }

    public var group: Group {
        switch self {
        case .from, .sentTo, .senderContains, .recipientContains, .sentToMe, .sentOnlyToMe, .sentCcMe,
             .sentToOrCcMe, .notSentToMe: .people
        case .subjectContains, .bodyContains, .bodyOrSubjectContains, .headerContains: .words
        case .importance, .sensitivity, .categories, .messageActionFlag, .hasAttachments, .withinSizeRange: .marked
        default: .type
        }
    }

    public static func kinds(in group: Group) -> [RuleConditionKind] { allCases.filter { $0.group == group } }

    public var title: String {
        switch self {
        case .from: L("보낸 사람")
        case .sentTo: L("받는 사람")
        case .senderContains: L("보낸 사람 주소에 포함")
        case .recipientContains: L("받는 사람 주소에 포함")
        case .sentToMe: L("받는 사람 줄에 내가 있음")
        case .sentOnlyToMe: L("나에게만 보냄")
        case .sentCcMe: L("참조 줄에 내가 있음")
        case .sentToOrCcMe: L("받는 사람이나 참조 줄에 내가 있음")
        case .notSentToMe: L("받는 사람 줄에 내가 없음")
        case .subjectContains: L("제목에 포함")
        case .bodyContains: L("본문에 포함")
        case .bodyOrSubjectContains: L("제목이나 본문에 포함")
        case .headerContains: L("메시지 헤더에 포함")
        case .importance: L("중요도")
        case .sensitivity: L("민감도")
        case .categories: L("범주")
        case .messageActionFlag: L("플래그 표시")
        case .hasAttachments: L("첨부 파일 있음")
        case .withinSizeRange: L("크기 범위")
        case .isMeetingRequest: L("회의 요청")
        case .isMeetingResponse: L("회의 응답")
        case .isAutomaticReply: L("자동 회신")
        case .isAutomaticForward: L("자동 전달")
        case .isReadReceipt: L("읽음 확인")
        case .isNonDeliveryReport: L("배달하지 못함 알림")
        case .isEncrypted: L("암호화됨")
        case .isSigned: L("디지털 서명됨")
        case .isApprovalRequest: L("승인 요청")
        case .isVoicemail: L("음성 메일")
        case .isPermissionControlled: L("권한 보호됨")
        }
    }

    public static func groupTitle(_ g: Group) -> String {
        switch g {
        case .people: L("사람")
        case .words: L("글자")
        case .marked: L("표시")
        case .type: L("메시지 종류")
        }
    }

    /// 예: "제목에 '%@' 포함"의 앞뒤
    func wordsSummary(_ list: String) -> String {
        switch self {
        case .senderContains: L("보낸 사람 주소에 '\(list)' 포함")
        case .recipientContains: L("받는 사람 주소에 '\(list)' 포함")
        case .subjectContains: L("제목에 '\(list)' 포함")
        case .bodyContains: L("본문에 '\(list)' 포함")
        case .bodyOrSubjectContains: L("제목이나 본문에 '\(list)' 포함")
        case .headerContains: L("헤더에 '\(list)' 포함")
        case .categories: L("범주 '\(list)'")
        default: "\(title) '\(list)'"
        }
    }
}

/// 고르는 값의 이름 (중요도, 민감도, 플래그)
public enum RuleValue {
    public static let importance = ["low", "normal", "high"]  // l10n: data
    public static let sensitivity = ["normal", "personal", "private", "confidential"]  // l10n: data
    public static let flag = ["any", "followUp", "call", "doNotForward", "forward", "fyi",  // l10n: data
                              "noResponseNecessary", "read", "reply", "replyToAll", "review"]  // l10n: data

    public static func title(_ value: String) -> String {
        switch value {
        case "low": L("낮음")
        case "normal": L("보통")
        case "high": L("높음")
        case "personal": L("개인")
        case "private": L("사적")
        case "confidential": L("기밀")
        case "any": L("모든 플래그")
        case "followUp": L("후속 조치")
        case "call": L("전화")
        case "doNotForward": L("전달 안 함")
        case "forward": L("전달")
        case "fyi": L("참고용")
        case "noResponseNecessary": L("회신 필요 없음")
        case "read": L("읽기")
        case "reply": L("회신")
        case "replyToAll": L("전체 회신")
        case "review": L("검토")
        default: value
        }
    }
}

/// 쉼표로 나눈 글자·주소
enum RuleText {
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func addresses(_ text: String) -> [String] {
        words(text).compactMap { raw in
            var s = raw
            if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt { s = String(s[s.index(after: lt)..<gt]) }
            s = s.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }

    static func isAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !s.contains(where: \.isWhitespace)
    }

    static func quoted(_ list: [String]) -> String { list.joined(separator: "', '") }
}

/// 조건·예외 한 줄
public struct RuleCondition: Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: RuleConditionKind
    /// 글자·주소 (쉼표로 여러 개)
    public var text: String
    /// 중요도·민감도·플래그 값
    public var choice: String
    /// 크기 범위 (KB). 위쪽이 비면 끝 없음.
    public var minKB: Int?
    public var maxKB: Int?

    public init(kind: RuleConditionKind, text: String = "", choice: String? = nil, minKB: Int? = nil, maxKB: Int? = nil) {
        self.kind = kind
        self.text = text
        let fallback: String = switch kind.input {
        case .importance: "high"
        case .sensitivity: "confidential"
        case .flag: "any"
        default: ""
        }
        self.choice = choice ?? fallback
        self.minKB = minKB
        self.maxKB = maxKB
    }

    public var words: [String] { RuleText.words(text) }
    public var addresses: [String] { RuleText.addresses(text) }

    /// 크기 위쪽 끝이 없을 때 서버에 보내는 값 (KB, 약 1 GB)
    public static let noUpperKB = 999_999

    /// 고쳐야 할 점, 없으면 nil
    public var problem: String? {
        switch kind.input {
        case .words where words.isEmpty: return L("'\(kind.title)'에 글자를 넣으세요.")
        case .addresses where addresses.isEmpty: return L("'\(kind.title)'에 주소를 넣으세요.")
        case .addresses:
            if let bad = addresses.first(where: { !RuleText.isAddress($0) }) { return L("'\(bad)'는 메일 주소가 아닙니다.") }
            return nil
        case .size:
            if minKB == nil && maxKB == nil { return L("크기 범위에 숫자를 넣으세요.") }
            if let a = minKB, let b = maxKB, a > b { return L("크기 범위의 처음 값이 끝 값보다 큽니다.") }
            return nil
        default: return nil
        }
    }

    public var summary: String {
        switch kind.input {
        case .none: return kind.title
        case .words: return kind.wordsSummary(RuleText.quoted(words))
        case .addresses: return kind == .from ? L("보낸 사람 '\(RuleText.quoted(addresses))'") : L("받는 사람 '\(RuleText.quoted(addresses))'")
        case .importance: return L("중요도 \(RuleValue.title(choice))")
        case .sensitivity: return L("민감도 \(RuleValue.title(choice))")
        case .flag: return L("플래그 \(RuleValue.title(choice))")
        case .size:
            let lo = minKB ?? 0
            if let hi = maxKB, hi < Self.noUpperKB { return L("크기 \(lo)–\(hi)KB") }
            return L("크기 \(lo)KB 이상")
        }
    }
}

/// 동작 한 줄의 종류 (Graph messageRuleActions)
public enum RuleActionKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case moveToFolder, copyToFolder, delete, permanentDelete, markAsRead, markImportance, assignCategories
    case forwardTo, forwardAsAttachmentTo, redirectTo

    public var id: String { rawValue }

    public enum Input: Sendable { case none, folder, importance, words, addresses }

    public var input: Input {
        switch self {
        case .moveToFolder, .copyToFolder: .folder
        case .markImportance: .importance
        case .assignCategories: .words
        case .forwardTo, .forwardAsAttachmentTo, .redirectTo: .addresses
        default: .none
        }
    }

    public var title: String {
        switch self {
        case .moveToFolder: L("폴더로 이동")
        case .copyToFolder: L("폴더에 복사")
        case .delete: L("지우기")
        case .permanentDelete: L("영구 삭제")
        case .markAsRead: L("읽음으로 표시")
        case .markImportance: L("중요도 지정")
        case .assignCategories: L("범주 지정")
        case .forwardTo: L("전달")
        case .forwardAsAttachmentTo: L("첨부 파일로 전달")
        case .redirectTo: L("리디렉션")
        }
    }

    /// 지금 실행에서 이 Mac이 하지 않는 동작 (예전 메일을 한꺼번에 남에게 보내지 않게)
    public var sendsMail: Bool { input == .addresses }
}

/// 동작 한 줄
public struct RuleAction: Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: RuleActionKind
    public var folderID: String?
    public var text: String
    public var choice: String

    public init(kind: RuleActionKind, folderID: String? = nil, text: String = "", choice: String? = nil) {
        self.kind = kind
        self.folderID = folderID
        self.text = text
        self.choice = choice ?? (kind == .markImportance ? "high" : "")
    }

    public var words: [String] { RuleText.words(text) }
    public var addresses: [String] { RuleText.addresses(text) }

    public var problem: String? {
        switch kind.input {
        case .folder where folderID == nil: return L("'\(kind.title)'에 폴더를 고르세요.")
        case .words where words.isEmpty: return L("'\(kind.title)'에 범주 이름을 넣으세요.")
        case .addresses where addresses.isEmpty: return L("'\(kind.title)'에 주소를 넣으세요.")
        case .addresses:
            if let bad = addresses.first(where: { !RuleText.isAddress($0) }) { return L("'\(bad)'는 메일 주소가 아닙니다.") }
            return nil
        default: return nil
        }
    }

    public func summary(folderName: (String) -> String?) -> String {
        let folder = folderID.flatMap(folderName) ?? L("다른 폴더")
        switch kind {
        case .moveToFolder: return L("\(folder)로 이동")
        case .copyToFolder: return L("\(folder)에 복사")
        case .markImportance: return L("중요도 \(RuleValue.title(choice))")
        case .assignCategories: return L("범주 '\(RuleText.quoted(words))'")
        case .forwardTo: return L("\(addresses.joined(separator: ", "))에게 전달")
        case .forwardAsAttachmentTo: return L("\(addresses.joined(separator: ", "))에게 첨부 파일로 전달")
        case .redirectTo: return L("\(addresses.joined(separator: ", "))에게 리디렉션")
        default: return kind.title
        }
    }
}

/// 규칙 편집 창의 값: 이름, 조건, 동작, 예외, 다음 규칙 처리 안 함.
public struct RuleForm: Equatable, Sendable {
    public var name: String
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    public var exceptions: [RuleCondition]
    /// 이 규칙이 맞으면 다음 규칙은 보지 않는다 (Outlook 기본값: 켬)
    public var stopProcessing: Bool
    public var isEnabled: Bool

    public init(name: String = "", conditions: [RuleCondition] = [], actions: [RuleAction] = [],
                exceptions: [RuleCondition] = [], stopProcessing: Bool = true, isEnabled: Bool = true) {
        self.name = name
        self.conditions = conditions
        self.actions = actions
        self.exceptions = exceptions
        self.stopProcessing = stopProcessing
        self.isEnabled = isEnabled
    }

    /// 서버 규칙을 편집 창 값으로
    public init(rule: MessageRule) {
        self.init(name: rule.displayName,
                  conditions: Self.items(rule.conditions),
                  actions: Self.items(rule.actions),
                  exceptions: Self.items(rule.exceptions),
                  stopProcessing: rule.actions?.stopProcessingRules ?? false,
                  isEnabled: rule.isEnabled ?? true)
    }

    /// 아직 쓰지 않은 종류 (한 종류는 한 번만)
    public func unusedConditions(exceptions isException: Bool) -> Set<RuleConditionKind> {
        Set(RuleConditionKind.allCases).subtracting((isException ? exceptions : conditions).map(\.kind))
    }

    public var unusedActions: Set<RuleActionKind> { Set(RuleActionKind.allCases).subtracting(actions.map(\.kind)) }

    /// 처음 고쳐야 할 점 (저장 단추 옆에 보인다)
    public var problem: String? {
        if actions.isEmpty { return L("동작을 하나 이상 추가하세요.") }
        return (conditions + exceptions).lazy.compactMap(\.problem).first ?? actions.lazy.compactMap(\.problem).first
    }

    public var isValid: Bool { problem == nil }

    /// 이름이 비면 첫 조건 설명
    public var title: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return conditions.first?.summary ?? L("새 규칙")
    }

    public func rule(sequence: Int, id: String = "") -> MessageRule {
        let ex = Self.predicates(exceptions)
        var acts = Self.actions(actions)
        acts.stopProcessingRules = stopProcessing
        return MessageRule(id: id, displayName: title, sequence: sequence, isEnabled: isEnabled,
                           conditions: Self.predicates(conditions), exceptions: ex.isEmpty ? nil : ex, actions: acts)
    }

    // MARK: 바꾸기

    public static func predicates(_ items: [RuleCondition]) -> RulePredicates {
        var p = RulePredicates()
        for c in items {
            let people = c.addresses.map { Recipient(name: nil, address: $0) }
            switch c.kind {
            case .from: p.fromAddresses = people
            case .sentTo: p.sentToAddresses = people
            case .senderContains: p.senderContains = c.words
            case .recipientContains: p.recipientContains = c.words
            case .sentToMe: p.sentToMe = true
            case .sentOnlyToMe: p.sentOnlyToMe = true
            case .sentCcMe: p.sentCcMe = true
            case .sentToOrCcMe: p.sentToOrCcMe = true
            case .notSentToMe: p.notSentToMe = true
            case .subjectContains: p.subjectContains = c.words
            case .bodyContains: p.bodyContains = c.words
            case .bodyOrSubjectContains: p.bodyOrSubjectContains = c.words
            case .headerContains: p.headerContains = c.words
            case .importance: p.importance = c.choice
            case .sensitivity: p.sensitivity = c.choice
            case .categories: p.categories = c.words
            case .messageActionFlag: p.messageActionFlag = c.choice
            case .hasAttachments: p.hasAttachments = true
            case .withinSizeRange:
                p.withinSizeRange = .init(minimumSize: c.minKB ?? 0, maximumSize: c.maxKB ?? RuleCondition.noUpperKB)
            case .isMeetingRequest: p.isMeetingRequest = true
            case .isMeetingResponse: p.isMeetingResponse = true
            case .isAutomaticReply: p.isAutomaticReply = true
            case .isAutomaticForward: p.isAutomaticForward = true
            case .isReadReceipt: p.isReadReceipt = true
            case .isNonDeliveryReport: p.isNonDeliveryReport = true
            case .isEncrypted: p.isEncrypted = true
            case .isSigned: p.isSigned = true
            case .isApprovalRequest: p.isApprovalRequest = true
            case .isVoicemail: p.isVoicemail = true
            case .isPermissionControlled: p.isPermissionControlled = true
            }
        }
        return p
    }

    public static func items(_ raw: RulePredicates?) -> [RuleCondition] {
        guard let p = raw?.cleaned else { return [] }
        func addr(_ r: [Recipient]?) -> String { (r ?? []).compactMap(\.emailAddress.address).joined(separator: ", ") }
        func join(_ w: [String]?) -> String { (w ?? []).joined(separator: ", ") }
        var out: [RuleCondition] = []
        for kind in RuleConditionKind.allCases {
            let item: RuleCondition? = switch kind {
            case .from: p.fromAddresses.map { _ in .init(kind: kind, text: addr(p.fromAddresses)) }
            case .sentTo: p.sentToAddresses.map { _ in .init(kind: kind, text: addr(p.sentToAddresses)) }
            case .senderContains: p.senderContains.map { .init(kind: kind, text: join($0)) }
            case .recipientContains: p.recipientContains.map { .init(kind: kind, text: join($0)) }
            case .subjectContains: p.subjectContains.map { .init(kind: kind, text: join($0)) }
            case .bodyContains: p.bodyContains.map { .init(kind: kind, text: join($0)) }
            case .bodyOrSubjectContains: p.bodyOrSubjectContains.map { .init(kind: kind, text: join($0)) }
            case .headerContains: p.headerContains.map { .init(kind: kind, text: join($0)) }
            case .categories: p.categories.map { .init(kind: kind, text: join($0)) }
            case .importance: p.importance.map { .init(kind: kind, choice: $0) }
            case .sensitivity: p.sensitivity.map { .init(kind: kind, choice: $0) }
            case .messageActionFlag: p.messageActionFlag.map { .init(kind: kind, choice: $0) }
            case .withinSizeRange: p.withinSizeRange.map {
                .init(kind: kind, minKB: $0.minimumSize,
                      maxKB: ($0.maximumSize ?? RuleCondition.noUpperKB) >= RuleCondition.noUpperKB ? nil : $0.maximumSize)
            }
            case .sentToMe: p.sentToMe.map { _ in .init(kind: kind) }
            case .sentOnlyToMe: p.sentOnlyToMe.map { _ in .init(kind: kind) }
            case .sentCcMe: p.sentCcMe.map { _ in .init(kind: kind) }
            case .sentToOrCcMe: p.sentToOrCcMe.map { _ in .init(kind: kind) }
            case .notSentToMe: p.notSentToMe.map { _ in .init(kind: kind) }
            case .hasAttachments: p.hasAttachments.map { _ in .init(kind: kind) }
            case .isMeetingRequest: p.isMeetingRequest.map { _ in .init(kind: kind) }
            case .isMeetingResponse: p.isMeetingResponse.map { _ in .init(kind: kind) }
            case .isAutomaticReply: p.isAutomaticReply.map { _ in .init(kind: kind) }
            case .isAutomaticForward: p.isAutomaticForward.map { _ in .init(kind: kind) }
            case .isReadReceipt: p.isReadReceipt.map { _ in .init(kind: kind) }
            case .isNonDeliveryReport: p.isNonDeliveryReport.map { _ in .init(kind: kind) }
            case .isEncrypted: p.isEncrypted.map { _ in .init(kind: kind) }
            case .isSigned: p.isSigned.map { _ in .init(kind: kind) }
            case .isApprovalRequest: p.isApprovalRequest.map { _ in .init(kind: kind) }
            case .isVoicemail: p.isVoicemail.map { _ in .init(kind: kind) }
            case .isPermissionControlled: p.isPermissionControlled.map { _ in .init(kind: kind) }
            }
            if let item { out.append(item) }
        }
        return out
    }

    public static func actions(_ items: [RuleAction]) -> MessageRule.Actions {
        var a = MessageRule.Actions()
        for item in items {
            let people = item.addresses.map { Recipient(name: nil, address: $0) }
            switch item.kind {
            case .moveToFolder: a.moveToFolder = item.folderID
            case .copyToFolder: a.copyToFolder = item.folderID
            case .delete: a.delete = true
            case .permanentDelete: a.permanentDelete = true
            case .markAsRead: a.markAsRead = true
            case .markImportance: a.markImportance = item.choice
            case .assignCategories: a.assignCategories = item.words
            case .forwardTo: a.forwardTo = people
            case .forwardAsAttachmentTo: a.forwardAsAttachmentTo = people
            case .redirectTo: a.redirectTo = people
            }
        }
        return a
    }

    public static func items(_ raw: MessageRule.Actions?) -> [RuleAction] {
        guard let a = raw?.cleaned else { return [] }
        func addr(_ r: [Recipient]?) -> String? {
            r.map { $0.compactMap(\.emailAddress.address).joined(separator: ", ") }
        }
        var out: [RuleAction] = []
        if let f = a.moveToFolder { out.append(.init(kind: .moveToFolder, folderID: f)) }
        if let f = a.copyToFolder { out.append(.init(kind: .copyToFolder, folderID: f)) }
        if a.delete == true { out.append(.init(kind: .delete)) }
        if a.permanentDelete == true { out.append(.init(kind: .permanentDelete)) }
        if a.markAsRead == true { out.append(.init(kind: .markAsRead)) }
        if let i = a.markImportance { out.append(.init(kind: .markImportance, choice: i)) }
        if let c = a.assignCategories { out.append(.init(kind: .assignCategories, text: c.joined(separator: ", "))) }
        if let t = addr(a.forwardTo) { out.append(.init(kind: .forwardTo, text: t)) }
        if let t = addr(a.forwardAsAttachmentTo) { out.append(.init(kind: .forwardAsAttachmentTo, text: t)) }
        if let t = addr(a.redirectTo) { out.append(.init(kind: .redirectTo, text: t)) }
        return out
    }

    /// 메일 한 통에서 시작하는 규칙 (메시지 > 규칙 만들기): 보낸 사람 조건과 빈 폴더 이동
    public static func seed(from message: MailMessage) -> RuleForm {
        var form = RuleForm()
        if let address = message.from?.emailAddress.address {
            form.conditions = [RuleCondition(kind: .from, text: address)]
            form.name = message.from?.emailAddress.display ?? address
        } else if let s = message.subject, !s.isEmpty {
            form.conditions = [RuleCondition(kind: .subjectContains, text: s)]
        }
        form.actions = [RuleAction(kind: .moveToFolder)]
        return form
    }
}

// MARK: 지금 실행 (S-075)

/// 이미 받은 메일에 규칙을 이 Mac에서 적용할 때 맞는지 본다. Exchange가 새 메일에 하는 판단과 같게 맞춘다.
public enum RuleMatcher {
    /// 이 Mac이 메일 목록으로 판단할 수 없는 조건 (서버만 아는 값)
    public static func unsupported(_ rule: MessageRule) -> [RuleConditionKind] {
        let items = RuleForm.items(rule.conditions) + RuleForm.items(rule.exceptions)
        return items.filter { !isSupported($0) }.map(\.kind)
    }

    static func isSupported(_ c: RuleCondition) -> Bool {
        switch c.kind {
        case .sensitivity, .withinSizeRange, .isAutomaticReply, .isAutomaticForward, .isReadReceipt,
             .isNonDeliveryReport, .isEncrypted, .isSigned, .isApprovalRequest, .isVoicemail, .isPermissionControlled:
            false
        case .messageActionFlag: c.choice == "any"
        default: true
        }
    }

    /// 본문이나 헤더를 받아야 판단할 수 있는가
    public static func needsDetail(_ rule: MessageRule) -> Bool {
        let kinds = (RuleForm.items(rule.conditions) + RuleForm.items(rule.exceptions)).map(\.kind)
        return kinds.contains { [.bodyContains, .bodyOrSubjectContains, .headerContains].contains($0) }
    }

    /// 규칙이 이 메일에 맞는가. `me`는 내 주소들 (소문자로 비교). `ignoringDetail`이면 본문·헤더 조건은 맞는 것으로 보고
    /// 예외는 보지 않는다 (본문을 받기 전에 후보를 고를 때).
    public static func matches(_ rule: MessageRule, message m: MailMessage, me: [String], ignoringDetail: Bool = false) -> Bool {
        let mine = Set(me.map { $0.lowercased() })
        let conditions = RuleForm.items(rule.conditions)
        guard conditions.allSatisfy({ test($0, m, mine, ignoringDetail: ignoringDetail) }) else { return false }
        if ignoringDetail { return true }
        return !RuleForm.items(rule.exceptions).contains { test($0, m, mine, ignoringDetail: false) }
    }

    static func test(_ c: RuleCondition, _ m: MailMessage, _ me: Set<String>, ignoringDetail: Bool) -> Bool {
        func has(_ text: String?, _ words: [String]) -> Bool {
            guard let text, !text.isEmpty else { return false }
            return words.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        func addresses(_ r: [Recipient]?) -> [String] { (r ?? []).compactMap { $0.emailAddress.address?.lowercased() } }
        let to = addresses(m.toRecipients), cc = addresses(m.ccRecipients)
        let sender = m.from?.emailAddress
        let body: String? = m.body.map { $0.isHTML ? HTMLProcessor.plainText(from: $0.content) : $0.content } ?? m.bodyPreview
        switch c.kind {
        case .from:
            let list = Set(c.addresses.map { $0.lowercased() })
            return sender?.address.map { list.contains($0.lowercased()) } ?? false
        case .sentTo:
            let list = Set(c.addresses.map { $0.lowercased() })
            return !(Set(to + cc).isDisjoint(with: list))
        case .senderContains: return has(sender?.address, c.words) || has(sender?.name, c.words)
        case .recipientContains:
            let people = (m.toRecipients ?? []) + (m.ccRecipients ?? [])
            return people.contains { has($0.emailAddress.address, c.words) || has($0.emailAddress.name, c.words) }
        case .sentToMe: return !Set(to).isDisjoint(with: me)
        case .sentCcMe: return !Set(cc).isDisjoint(with: me)
        case .sentToOrCcMe: return !Set(to + cc).isDisjoint(with: me)
        case .sentOnlyToMe: return !to.isEmpty && Set(to).isSubset(of: me) && cc.isEmpty
        case .notSentToMe: return Set(to).isDisjoint(with: me)
        case .subjectContains: return has(m.subject, c.words)
        case .bodyContains: return ignoringDetail || has(body, c.words)
        case .bodyOrSubjectContains: return ignoringDetail || has(m.subject, c.words) || has(body, c.words)
        case .headerContains:
            if ignoringDetail { return true }
            return (m.internetMessageHeaders ?? []).contains { has("\($0.name): \($0.value)", c.words) }
        case .importance: return (m.importance ?? "normal").lowercased() == c.choice.lowercased()
        case .categories:
            let mineCats = Set((m.categories ?? []).map { $0.lowercased() })
            return c.words.contains { mineCats.contains($0.lowercased()) }
        case .messageActionFlag: return m.isFlagged
        case .hasAttachments: return m.hasAttachments == true
        case .isMeetingRequest: return m.isMeetingRequest
        case .isMeetingResponse: return m.odataType?.contains("eventMessageResponse") ?? false
        default: return false
        }
    }
}

/// 예전 설정 화면의 간단한 규칙 (조건 하나, 동작 하나). 셀프 테스트와 예전 시험이 쓴다.
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
    public var words: [String] { RuleText.words(text) }

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
