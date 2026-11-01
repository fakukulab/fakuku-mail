import Foundation
import Testing
@testable import ExchangeMailKit

// S-001 로그인

@Test("PKCE challenge는 RFC 7636 부록 B 예시와 같다")
func pkceChallenge() {
    #expect(OAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test("verifier는 43~128자 base64url")
func verifierShape() {
    let v = OAuth.randomVerifier()
    #expect((43...128).contains(v.count))
    #expect(v.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil)
}

@Test("인증 URL에 필요한 값이 모두 들어간다")
func authorizeURL() throws {
    let url = try #require(OAuth.authorizeURL(tenant: "", clientID: "cid", redirectURI: OAuth.redirectURI(bundleID: "com.example.exchangemail"),
                                              challenge: "ch", state: "st"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
    #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize"))
    #expect(v("client_id") == "cid")
    #expect(v("response_type") == "code")
    #expect(v("redirect_uri") == "msauth.com.example.exchangemail://auth")
    #expect(v("code_challenge") == "ch")
    #expect(v("code_challenge_method") == "S256")
    #expect(v("state") == "st")
    #expect(v("scope")?.contains("Mail.Send") == true)
}

@Test("리디렉션에서 code를 꺼내고 state가 다르면 거절한다")
func callback() throws {
    let ok = try #require(URL(string: "msauth.x://auth?code=abc&state=s1"))
    #expect(OAuth.code(from: ok, expectedState: "s1") == .success("abc"))
    #expect(OAuth.code(from: ok, expectedState: "s2") == .failure(.stateMismatch))
    let err = try #require(URL(string: "msauth.x://auth?error=access_denied&error_description=denied&state=s1"))
    #expect(OAuth.code(from: err, expectedState: "s1") == .failure(.server("denied")))
}

// S-002 폴더

@Test("폴더는 영어·한국어 이름 모두 같은 순서로 정렬된다")
func folderOrder() {
    let en = ["Deleted Items", "Inbox", "Projects", "Sent Items", "Drafts", "Archive", "Junk Email"]
        .enumerated().map { MailFolder(id: "\($0.offset)", displayName: $0.element) }
    let ko = ["지운 편지함", "받은 편지함", "프로젝트", "보낸 편지함", "임시 보관함", "보관", "정크 메일"]
        .enumerated().map { MailFolder(id: "\($0.offset)", displayName: $0.element) }
    let order = ["inbox", "drafts", "sentitems", "archive", "junkemail", "deleteditems", nil]
    #expect(FolderOrder.sorted(en).map(\.kind) == order)
    #expect(FolderOrder.sorted(ko).map(\.kind) == order)
    #expect(FolderOrder.sorted(en).first?.symbol == "tray")
}

// S-003, S-004 읽기

@Test("Graph 날짜를 소수 초가 있든 없든 읽는다", arguments: [
    "2024-05-01T10:00:00Z", "2024-05-01T10:00:00.1234567Z", "2024-05-01T10:00:00",
])
func graphDates(_ s: String) {
    let d = GraphJSON.parseDate(s)
    #expect(d == Date(timeIntervalSince1970: 1_714_557_600))
}

@Test("메시지 JSON을 디코딩한다")
func decodeMessage() throws {
    let json = """
    {"value":[{"id":"m1","subject":"안녕","from":{"emailAddress":{"name":"홍길동","address":"hong@x.com"}},
    "receivedDateTime":"2024-05-01T10:00:00Z","isRead":false,"hasAttachments":true,"bodyPreview":"미리보기"}],
    "@odata.nextLink":"https://graph.microsoft.com/v1.0/next"}
    """
    let list = try GraphJSON.decoder().decode(GraphList<MailMessage>.self, from: Data(json.utf8))
    #expect(list.value.first?.from?.emailAddress.display == "홍길동")
    #expect(list.value.first?.isUnread == true)
    #expect(list.nextLink == "https://graph.microsoft.com/v1.0/next")
}

@Test("목록 날짜: 오늘은 시각, 어제는 '어제'")
func listDates() throws {
    let tz = try #require(TimeZone(identifier: "Asia/Seoul"))
    let now = Date(timeIntervalSince1970: 1_714_557_600) // 2024-05-01 19:00 KST
    #expect(MailDate.listLabel(now.addingTimeInterval(-3_600), now: now, timeZone: tz).contains("6:00"))
    #expect(MailDate.listLabel(now.addingTimeInterval(-86_400), now: now, timeZone: tz) == "어제")
    #expect(MailDate.listLabel(now.addingTimeInterval(-86_400 * 30), now: now, timeZone: tz).contains("2024"))
}

@Test("cid 그림을 인라인 첨부의 data URI로 바꾼다")
func resolveCID() {
    let html = "<p><img src=\"cid:image001.png@01D9\"><img src='cid:missing'></p>"
    let att = FileAttachment(id: "a", name: "image001.png", contentType: "image/png", size: 3, isInline: true,
                             contentId: "<image001.png@01D9>", contentBytes: "AQID")
    let out = MailContent.resolveInlineImages(html: html, attachments: [att])
    #expect(out.contains("src=\"data:image/png;base64,AQID\""))
    #expect(out.contains("cid:missing"))
}

@Test("원격 그림을 찾아내고 차단 정책을 쓴다")
func remoteContent() {
    #expect(MailContent.hasRemoteContent("<img src=\"https://t.example/p.gif\">"))
    #expect(MailContent.hasRemoteContent("<td background='http://x/y.png'>"))
    #expect(MailContent.hasRemoteContent("<div style=\"background:url(//x/y.png)\">"))
    #expect(!MailContent.hasRemoteContent("<img src=\"data:image/png;base64,AA\">"))
    #expect(MailContent.page(body: nil, allowRemote: false).contains("img-src data:;"))
    #expect(MailContent.page(body: nil, allowRemote: true).contains("img-src * data:"))
}

@Test("평문 본문은 HTML로 이스케이프한다")
func plainBody() {
    let page = MailContent.page(body: .init(contentType: "text", content: "<b>x</b>"), allowRemote: false)
    #expect(page.contains("&lt;b&gt;x&lt;/b&gt;"))
}

// S-014 검색

@Test("검색 요청은 $search와 ConsistencyLevel을 쓰고 $orderby는 쓰지 않는다")
func searchQuery() {
    let s = GraphQuery.messageList(search: "견적")
    #expect(s.query["$search"] == "\"견적\"")
    #expect(s.query["$orderby"] == nil)
    #expect(s.headers["ConsistencyLevel"] == "eventual")
    let l = GraphQuery.messageList(search: "  ")
    #expect(l.query["$orderby"] == "receivedDateTime desc")
    #expect(l.query["$search"] == nil)
}

// S-006 받는 사람

@Test("받는 사람 칸을 주소 목록으로 읽는다")
func parseAddresses() {
    let r = AddressParser.parse("홍길동 <hong@x.com>; \"Kim, Lee\" <kl@y.co.kr>, c@d.com\n잘못된주소, hong@x.com")
    #expect(r.valid.map(\.address) == ["hong@x.com", "kl@y.co.kr", "c@d.com"])
    #expect(r.valid[0].name == "홍길동")
    #expect(r.valid[1].name == "Kim, Lee")
    #expect(r.invalid == ["잘못된주소"])
}

// S-007 답장, 전달

let original = MailMessage(
    id: "g1", internetMessageId: "<orig@x>", subject: "견적 문의",
    from: Recipient(name: "고객", address: "client@x.com"),
    toRecipients: [Recipient(name: "나", address: "me@corp.com"), Recipient(name: "동료", address: "peer@corp.com")],
    ccRecipients: [Recipient(name: "팀장", address: "lead@corp.com")],
    receivedDateTime: Date(timeIntervalSince1970: 1_714_557_600), isRead: true, hasAttachments: true,
    body: .init(contentType: "html", content: "<html><head><style>p{}</style></head><body><p>본문</p></body></html>"),
    internetMessageHeaders: [InternetHeader(name: "References", value: "<root@x>")])

@Test("답장 제목 접두어는 한 번만", arguments: [
    (ComposeKind.reply, "견적", "RE: 견적"),
    (.reply, "RE: 견적", "RE: 견적"),
    (.reply, "회신: 견적", "회신: 견적"),
    (.replyAll, "re: 견적", "re: 견적"),
    (.forward, "견적", "FW: 견적"),
    (.forward, "전달: 견적", "전달: 견적"),
    (.forward, "RE: 견적", "FW: RE: 견적"),
])
func subjects(_ kind: ComposeKind, _ input: String, _ expected: String) {
    #expect(ReplyBuilder.subject(for: kind, original: input) == expected)
}

@Test("전체 답장은 내 주소를 빼고 나머지를 참조로 넣는다")
func replyAllRecipients() {
    let r = ReplyBuilder.recipients(for: .replyAll, message: original, myAddress: "ME@corp.com")
    #expect(r.to.map(\.address) == ["client@x.com"])
    #expect(r.cc.map(\.address) == ["peer@corp.com", "lead@corp.com"])
    let single = ReplyBuilder.recipients(for: .reply, message: original, myAddress: "me@corp.com")
    #expect(single.cc.isEmpty)
}

@Test("답장 초안은 스레드 헤더와 인용문을 갖는다")
func replyDraft() {
    let d = ReplyBuilder.draft(kind: .reply, message: original, bodyHTML: original.body!.content, myAddress: "me@corp.com")
    #expect(d.inReplyTo == "<orig@x>")
    #expect(d.references == ["<root@x>", "<orig@x>"])
    #expect(d.quoteHTML.contains("data-quote"))
    #expect(d.quoteHTML.contains("<p>본문</p>"))
    #expect(!d.quoteHTML.contains("<html"))
    #expect(!d.quoteHTML.contains("<style"))
    #expect(d.to == "고객 <client@x.com>")
}

@Test("전달 초안은 첨부를 가져올 원본을 기억한다")
func forwardDraft() {
    let d = ReplyBuilder.draft(kind: .forward, message: original, bodyHTML: "<p>본문</p>", myAddress: nil)
    #expect(d.forwardAttachmentsFrom == "g1")
    #expect(d.to.isEmpty)
    #expect(d.quoteHTML.contains("전달된 메시지"))
}

// S-009, S-010 서명

@Test("계정 규칙이 전역 규칙보다 앞서고, 전체 답장은 답장 규칙을 따른다")
func signatureRules() {
    let a = UUID(), b = UUID()
    var rules = SignatureRules()
    rules.defaults["new"] = a
    rules.defaults["reply"] = a
    rules.perAccount["me@x.com"] = ["reply": b]
    #expect(rules.signatureID(kind: .new, account: "ME@x.com") == a)
    #expect(rules.signatureID(kind: .reply, account: "me@x.com") == b)
    #expect(rules.signatureID(kind: .replyAll, account: "me@x.com") == b)
    #expect(rules.signatureID(kind: .forward, account: "me@x.com") == nil)
    rules.defaults["forward"] = SignatureRules.noneID
    #expect(rules.signatureID(kind: .forward, account: nil) == nil)
    rules.forget(a)
    #expect(rules.defaults["new"] == nil)
}

@Test("서명 교체는 블록 하나만 바꾸고 인용문 앞자리를 지킨다")
func signatureReplace() {
    let s1 = Signature(name: "1", html: "A"), s2 = Signature(name: "2", html: "B")
    let quote = "<div data-quote=\"reply\"><p>인용</p></div>"
    var body = "<p>hi</p>" + SignatureComposer.block(for: s1) + quote
    body = SignatureComposer.replace(in: body, with: s2)
    #expect(body.contains(s2.id.uuidString))
    #expect(!body.contains(s1.id.uuidString))
    #expect(body.range(of: s2.id.uuidString)!.lowerBound < body.range(of: "data-quote")!.lowerBound)
    let none = SignatureComposer.replace(in: body, with: nil)
    #expect(!none.contains("data-signature"))
    let added = SignatureComposer.replace(in: "<p>hi</p>" + quote, with: s1)
    #expect(added.range(of: "data-signature")!.lowerBound < added.range(of: "data-quote")!.lowerBound)
}
