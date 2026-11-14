import Foundation
import Testing
@testable import ExchangeMailKit

// S-075 Outlook과 같은 규칙

private func message(subject: String = "회의", from: String = "boss@contoso.com", to: [String] = ["me@contoso.com"],
                     cc: [String] = [], attachments: Bool = false) -> MailMessage {
    var m = MailMessage(id: "m", subject: subject, from: Recipient(name: "부장님", address: from),
                        toRecipients: to.map { Recipient(name: nil, address: $0) },
                        ccRecipients: cc.map { Recipient(name: nil, address: $0) },
                        receivedDateTime: nil, bodyPreview: "다음 주 견적 회의", hasAttachments: attachments)
    m.importance = "normal"
    return m
}

@Test("조건·예외·동작을 Graph 규칙 본문으로 만든다")
func ruleFormBody() throws {
    var form = RuleForm(name: "견적")
    form.conditions = [RuleCondition(kind: .from, text: "Boss <boss@contoso.com>, a@b.com"),
                       RuleCondition(kind: .subjectContains, text: "견적; 발주"),
                       RuleCondition(kind: .hasAttachments),
                       RuleCondition(kind: .withinSizeRange, minKB: 100)]
    form.exceptions = [RuleCondition(kind: .importance, choice: "low")]
    form.actions = [RuleAction(kind: .moveToFolder, folderID: "f1"),
                    RuleAction(kind: .assignCategories, text: "견적"),
                    RuleAction(kind: .forwardTo, text: "x@y.com")]
    form.stopProcessing = false
    #expect(form.isValid)
    let rule = form.rule(sequence: 4)
    let body = rule.createBody
    let c = try #require(body["conditions"] as? [String: Any])
    let from = try #require(c["fromAddresses"] as? [[String: Any]])
    #expect((from.first?["emailAddress"] as? [String: Any])?["address"] as? String == "boss@contoso.com")
    #expect(from.count == 2)
    #expect(c["subjectContains"] as? [String] == ["견적", "발주"])
    #expect(c["hasAttachments"] as? Bool == true)
    #expect((c["withinSizeRange"] as? [String: Any])?["maximumSize"] as? Int == RuleCondition.noUpperKB)
    #expect(c["bodyContains"] == nil)
    #expect((body["exceptions"] as? [String: Any])?["importance"] as? String == "low")
    let a = try #require(body["actions"] as? [String: Any])
    #expect(a["moveToFolder"] as? String == "f1")
    #expect(a["stopProcessingRules"] as? Bool == false)
    #expect((a["forwardTo"] as? [[String: Any]])?.count == 1)
    #expect(a["delete"] == nil)
    #expect(body["sequence"] as? Int == 4)

    // 다시 편집 창 값으로: 같은 조건·동작이 같은 차례로 나온다
    let back = RuleForm(rule: rule)
    #expect(back.conditions.map(\.kind) == [.from, .subjectContains, .hasAttachments, .withinSizeRange])
    #expect(back.conditions[0].addresses == ["boss@contoso.com", "a@b.com"])
    #expect(back.conditions[3].minKB == 100 && back.conditions[3].maxKB == nil)
    #expect(back.exceptions.map(\.kind) == [.importance])
    #expect(back.actions.map(\.kind) == [.moveToFolder, .assignCategories, .forwardTo])
    #expect(!back.stopProcessing)
    #expect(RuleForm.predicates(back.conditions) == rule.conditions)
}

@Test("빈 조건만 있는 서버 규칙: false와 빈 목록은 조건이 아니다")
func rulePredicatesCleaned() throws {
    let json = """
    {"id":"r1","displayName":"Outlook 규칙","sequence":2,"isEnabled":true,"hasError":false,
     "conditions":{"subjectContains":["보고"],"hasAttachments":false,"bodyContains":[]},
     "actions":{"markAsRead":true,"stopProcessingRules":true,"delete":false}}
    """
    let rule = try JSONDecoder().decode(MessageRule.self, from: Data(json.utf8))
    let form = RuleForm(rule: rule)
    #expect(form.conditions.map(\.kind) == [.subjectContains])
    #expect(form.actions.map(\.kind) == [.markAsRead])
    #expect(form.stopProcessing)
    #expect(rule.summary { _ in nil } == "제목에 '보고' 포함 → 읽음으로 표시")
}

@Test("고쳐야 할 점을 알려 준다")
func ruleFormProblems() {
    var form = RuleForm()
    #expect(form.problem == "동작을 하나 이상 추가하세요.")
    form.actions = [RuleAction(kind: .moveToFolder)]
    #expect(form.problem == "'폴더로 이동'에 폴더를 고르세요.")
    form.actions = [RuleAction(kind: .delete)]
    form.conditions = [RuleCondition(kind: .from, text: "누구")]
    #expect(form.problem == "'누구'는 메일 주소가 아닙니다.")
    form.conditions = [RuleCondition(kind: .withinSizeRange, minKB: 50, maxKB: 10)]
    #expect(form.problem != nil)
    form.conditions = []
    #expect(form.isValid)
    #expect(form.title == "새 규칙")
    #expect(form.unusedActions.contains(.delete) == false)
}

@Test("이미 받은 메일에 규칙이 맞는지 본다")
func ruleMatcher() {
    var form = RuleForm()
    form.actions = [RuleAction(kind: .markAsRead)]
    form.conditions = [RuleCondition(kind: .senderContains, text: "contoso"),
                       RuleCondition(kind: .sentOnlyToMe)]
    var rule = form.rule(sequence: 1)
    let me = ["ME@contoso.com"]
    #expect(RuleMatcher.matches(rule, message: message(), me: me))
    #expect(!RuleMatcher.matches(rule, message: message(cc: ["other@x.com"]), me: me))
    #expect(!RuleMatcher.matches(rule, message: message(from: "a@fabrikam.com"), me: me))

    // 예외: 첨부가 있으면 건너뛴다
    form.exceptions = [RuleCondition(kind: .hasAttachments)]
    rule = form.rule(sequence: 1)
    #expect(!RuleMatcher.matches(rule, message: message(attachments: true), me: me))
    #expect(RuleMatcher.matches(rule, message: message(attachments: true), me: me, ignoringDetail: true))

    // 본문 조건은 본문을 받기 전에는 후보로만 본다
    form = RuleForm(conditions: [RuleCondition(kind: .bodyContains, text: "견적")], actions: [RuleAction(kind: .delete)])
    rule = form.rule(sequence: 1)
    #expect(RuleMatcher.needsDetail(rule))
    var m = message()
    m.body = .init(contentType: "html", content: "<p>다른 이야기</p>")
    #expect(!RuleMatcher.matches(rule, message: m, me: me))
    #expect(RuleMatcher.matches(rule, message: m, me: me, ignoringDetail: true))
    m.body = .init(contentType: "html", content: "<p>3분기 <b>견적</b></p>")
    #expect(RuleMatcher.matches(rule, message: m, me: me))

    // 서버만 아는 조건은 지금 실행할 수 없다
    form.conditions = [RuleCondition(kind: .sensitivity), RuleCondition(kind: .messageActionFlag, choice: "any")]
    #expect(RuleMatcher.unsupported(form.rule(sequence: 1)) == [.sensitivity])
}

@Test("메일에서 규칙 만들기")
func ruleSeed() {
    let form = RuleForm.seed(from: message())
    #expect(form.name == "부장님")
    #expect(form.conditions.first?.kind == .from && form.conditions.first?.text == "boss@contoso.com")
    #expect(form.actions.map(\.kind) == [.moveToFolder])
    #expect(!form.isValid)   // 폴더를 골라야 한다
}
