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
    let url = try #require(OAuth.authorizeURL(tenant: "", clientID: "cid", redirectURI: OAuth.redirectURI(bundleID: "com.fakukulab.fakukumail"),
                                              challenge: "ch", state: "st"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
    #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize"))
    #expect(v("client_id") == "cid")
    #expect(v("response_type") == "code")
    #expect(v("redirect_uri") == "msauth.com.fakukulab.fakukumail://auth")
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

// S-018 받는 사람 자동완성

@Test("자동완성은 마지막 항목을 이름이나 주소로 찾고, 칸에 있는 주소와 내 주소는 뺀다")
func addressSuggestions() {
    var book = AddressBook()
    let minji = MailAddress(name: "김민지", address: "minji.kim@fabrikam.com")
    let min = MailAddress(name: "민경호", address: "kh.min@contoso.co.kr")
    let me = MailAddress(name: "나", address: "me@contoso.co.kr")
    book.noteSeen([minji, min, me], me: "ME@contoso.co.kr")
    #expect(book.entries.count == 2)
    #expect(book.suggestions(for: "민").map(\.address) == ["kh.min@contoso.co.kr", "minji.kim@fabrikam.com"])
    #expect(book.suggestions(for: "min").count == 2)
    #expect(book.suggestions(for: "김민지 <minji.kim@fabrikam.com>, 민").map(\.address) == ["kh.min@contoso.co.kr"])
    #expect(book.suggestions(for: "").isEmpty)
    #expect(book.suggestions(for: "a, ").isEmpty)
}

@Test("많이 보낸 사람이 위로 온다")
func sentRanksHigher() {
    var book = AddressBook()
    let a = MailAddress(name: "박서준", address: "seojun.park@fabrikam.com")
    let b = MailAddress(name: "박서연", address: "seoyeon.park@fabrikam.com")
    book.noteSeen([a, b], me: nil)
    book.noteSeen([a], me: nil)
    book.noteSent([b], me: nil)
    #expect(book.suggestions(for: "박").first?.address == "seoyeon.park@fabrikam.com")
}

@Test("고른 주소로 마지막 항목을 바꾼다", arguments: [
    ("민", "김민지 <minji.kim@fabrikam.com>, "),
    ("a@b.com, 민", "a@b.com, 김민지 <minji.kim@fabrikam.com>, "),
    ("\"Kim, Lee\" <kl@y.co.kr>; 민", "\"Kim, Lee\" <kl@y.co.kr>; 김민지 <minji.kim@fabrikam.com>, "),
])
func completeAddress(_ input: String, _ expected: String) {
    let minji = MailAddress(name: "김민지", address: "minji.kim@fabrikam.com")
    #expect(AddressBook.complete(input, with: minji) == expected)
}

// S-021 계정별 기본 서명

@Test("계정 규칙은 따르기·없음·서명을 고를 수 있고, 따르기는 전역 규칙으로 돌아간다")
func accountRuleChoices() {
    let a = UUID(), b = UUID()
    var rules = SignatureRules()
    rules.setChoice(.signature(a), kind: .reply, account: nil)
    #expect(rules.choice(kind: .reply, account: nil) == .signature(a))
    #expect(rules.choice(kind: .reply, account: "Me@x.com") == .inherit)
    #expect(rules.signatureID(kind: .replyAll, account: "me@x.com") == a)

    rules.setChoice(.signature(b), kind: .reply, account: "Me@x.com")
    #expect(rules.choice(kind: .replyAll, account: "me@x.com") == .signature(b))
    #expect(rules.signatureID(kind: .reply, account: "me@x.com") == b)

    rules.setChoice(.none, kind: .reply, account: "me@x.com")
    #expect(rules.signatureID(kind: .reply, account: "me@x.com") == nil)

    rules.setChoice(.inherit, kind: .reply, account: "me@x.com")
    #expect(rules.perAccount["me@x.com"] == nil)
    #expect(rules.signatureID(kind: .reply, account: "me@x.com") == a)

    rules.setChoice(.inherit, kind: .new, account: nil)
    #expect(rules.choice(kind: .new, account: nil) == RuleChoice.none)
}

// S-022 초안 이어서 쓰기

@Test("초안을 다시 열면 받는 사람·제목·본문·첨부를 그대로 옮긴다")
func resumeDraft() {
    var m = MailMessage(id: "d1", subject: "견적 초안", from: nil,
                        toRecipients: [Recipient(name: "고객", address: "client@x.com")],
                        ccRecipients: [Recipient(name: nil, address: "lead@corp.com")],
                        receivedDateTime: nil, hasAttachments: true,
                        internetMessageHeaders: [InternetHeader(name: "References", value: "<root@x> <orig@x>")])
    m.bccRecipients = [Recipient(name: nil, address: "hidden@corp.com")]
    let d = ReplyBuilder.resume(draft: m, bodyHTML: "<html><body><p>쓰던 글</p></body></html>")
    #expect(d.to == "고객 <client@x.com>")
    #expect(d.cc == "lead@corp.com")
    #expect(d.bcc == "hidden@corp.com")
    #expect(d.subject == "견적 초안")
    #expect(d.bodyHTML == "<p>쓰던 글</p>")
    #expect(d.draftMessageID == "d1")
    #expect(d.forwardAttachmentsFrom == "d1")
    #expect(d.inReplyTo == "<orig@x>")
}

// S-024 새 메일 알림

func inboxMessage(_ id: String, minutesAgo: Double, unread: Bool = true, from: String = "김민지",
                  now: Date = Date(timeIntervalSince1970: 1_714_557_600)) -> MailMessage {
    MailMessage(id: id, subject: "제목 \(id)", from: Recipient(name: from, address: "\(id)@x.com"),
                receivedDateTime: now.addingTimeInterval(-minutesAgo * 60), bodyPreview: "미리보기 \(id)", isRead: !unread)
}

@Test("처음 확인은 기준만 정하고, 그 뒤 도착한 읽지 않은 메일만 한 번씩 알린다")
func newMailTracking() {
    let now = Date(timeIntervalSince1970: 1_714_557_600)
    var tracker = NewMailTracker()
    #expect(tracker.take([inboxMessage("a", minutesAgo: 10), inboxMessage("b", minutesAgo: 20)], now: now).isEmpty)
    let second = [inboxMessage("c", minutesAgo: 1), inboxMessage("d", minutesAgo: 2, unread: false),
                  inboxMessage("a", minutesAgo: 10), inboxMessage("b", minutesAgo: 20)]
    #expect(tracker.take(second, now: now).map(\.id) == ["c"])
    #expect(tracker.take(second, now: now).isEmpty)
    #expect(tracker.watermark == now.addingTimeInterval(-60))
}

@Test("빈 받은 편지함에서 시작해도 다음 메일을 알린다")
func newMailFromEmptyInbox() {
    let now = Date(timeIntervalSince1970: 1_714_557_600)
    var tracker = NewMailTracker()
    #expect(tracker.take([], now: now.addingTimeInterval(-300)).isEmpty)
    #expect(tracker.take([inboxMessage("x", minutesAgo: 1)], now: now).map(\.id) == ["x"])
}

@Test("3통까지는 한 통씩, 4통부터는 요약 하나")
func notificationGrouping() {
    let three = ["a", "b", "c"].map { inboxMessage($0, minutesAgo: 1) }
    let singles = MailNotification.make(for: three)
    #expect(singles.count == 3)
    #expect(singles[0].title == "김민지")
    #expect(singles[0].subtitle == "제목 a")
    #expect(singles[0].messageID == "a")
    let five = (1...5).map { inboxMessage("m\($0)", minutesAgo: 1, from: "보낸이\($0)") }
    let summary = MailNotification.make(for: five)
    #expect(summary.count == 1)
    #expect(summary[0].title == "새 메일 5통")
    #expect(summary[0].subtitle == "보낸이1, 보낸이2, 보낸이3 외")
    #expect(summary[0].messageID == nil)
}

@Test("Dock 배지 글자", arguments: [(0, nil), (nil, nil), (3, "3"), (1200, "999+")] as [(Int?, String?)])
func dockBadge(_ n: Int?, _ expected: String?) {
    #expect(DockBadge.label(unread: n) == expected)
}

// S-025 대화별로 묶어 보기

func threadMessage(_ id: String, conv: String?, hoursAgo: Double, from: String, address: String,
                   unread: Bool = false, attach: Bool = false) -> MailMessage {
    MailMessage(id: id, conversationId: conv, subject: "견적", from: Recipient(name: from, address: address),
                receivedDateTime: Date(timeIntervalSince1970: 1_714_557_600 - hoursAgo * 3_600),
                isRead: !unread, hasAttachments: attach)
}

@Test("같은 대화는 한 줄로, 최근 순으로 묶는다")
func groupConversations() {
    let list = [
        threadMessage("a1", conv: "A", hoursAgo: 1, from: "김민지", address: "minji@x.com", unread: true),
        threadMessage("b1", conv: "B", hoursAgo: 2, from: "박서준", address: "sj@x.com"),
        threadMessage("a2", conv: "A", hoursAgo: 5, from: "나", address: "ME@corp.com", attach: true),
        threadMessage("a3", conv: "A", hoursAgo: 9, from: "김민지", address: "minji@x.com"),
        threadMessage("solo", conv: nil, hoursAgo: 3, from: "인사팀", address: "hr@corp.com"),
    ]
    let groups = Conversations.group(list)
    #expect(groups.map(\.latest.id) == ["a1", "b1", "solo"])
    #expect(groups[0].messageIDs == ["a1", "a2", "a3"])
    #expect(groups[0].count == 3)
    #expect(groups[0].isUnread)
    #expect(groups[0].hasAttachments)
    #expect(!groups[1].isUnread)
    #expect(groups[0].participants(me: "me@corp.com") == ["김민지", "나"])
    #expect(groups[2].count == 1)
}

@Test("대화 요청: 작은따옴표는 두 번, + 는 %2B")
func conversationQuery() {
    let r = GraphQuery.conversation(id: "AAQk+a/b='x'")
    #expect(r.query["$filter"] == "conversationId eq 'AAQk+a/b=''x'''")
    #expect(r.query["$orderby"] == nil)
    #expect(QueryEncoding.fixPlus("a=AAQk+a%2Fb") == "a=AAQk%2Ba%2Fb")
}

@Test("대화 보기는 오래된 메일부터")
func chronologicalThread() {
    let list = [threadMessage("new", conv: "A", hoursAgo: 1, from: "a", address: "a@x.com"),
                threadMessage("old", conv: "A", hoursAgo: 9, from: "b", address: "b@x.com")]
    #expect(Conversations.chronological(list).map(\.id) == ["old", "new"])
}

// S-026 오프라인 캐시

func tempCacheRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "mailcache-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Test("폴더, 목록, 본문, 첨부를 저장하고 다시 읽는다")
func cacheRoundTrip() throws {
    let base = tempCacheRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = MailCache.forAccount("Me@Corp.com", base: base)
    cache.saveFolders([MailFolder(id: "AAMk/+=", displayName: "받은 편지함", unreadItemCount: 3, wellKnownName: "inbox")])
    #expect(cache.folders()?.first?.wellKnownName == "inbox")
    #expect(cache.folders()?.first?.unreadItemCount == 3)

    let when = Date(timeIntervalSince1970: 1_714_557_600)
    let m = MailMessage(id: "id/with+slash", conversationId: "c1", subject: "견적", from: Recipient(name: "김민지", address: "m@x.com"),
                        receivedDateTime: when, bodyPreview: "미리", isRead: false, hasAttachments: true,
                        body: .init(contentType: "html", content: "<p>본문</p>"))
    cache.saveList(folderID: "AAMk/+=", messages: [m], nextLink: "next")
    let list = try #require(cache.list(folderID: "AAMk/+="))
    #expect(list.messages == [m])
    #expect(list.nextLink == "next")

    cache.saveMessage(m)
    let small = FileAttachment(id: "a1", name: "작은.pdf", contentType: "application/pdf", size: 10, isInline: false, contentBytes: "AQID")
    let big = FileAttachment(id: "a2", name: "큰.zip", contentType: "application/zip", size: 5_000_000, isInline: false, contentBytes: "AQID")
    let inline = FileAttachment(id: "a3", name: "logo.png", contentType: "image/png", size: 5_000_000, isInline: true,
                                contentId: "logo", contentBytes: "AQID")
    cache.saveAttachments([small, big, inline], messageID: m.id)
    let saved = try #require(cache.message(id: m.id))
    #expect(saved.message.body?.content == "<p>본문</p>")
    #expect(saved.attachments?.map(\.contentBytes) == ["AQID", nil, "AQID"])
    // 본문을 다시 저장해도 첨부는 남는다
    cache.saveMessage(m)
    #expect(cache.message(id: m.id)?.attachments?.count == 3)
    // 계정이 다르면 따로
    #expect(MailCache.forAccount("other@corp.com", base: base).folders() == nil)
    #expect(MailCache.forAccount("me@corp.com", base: base).folders() != nil)
    #expect(cache.sizeBytes() > 0)
    cache.clear()
    #expect(cache.folders() == nil)
    #expect(cache.sizeBytes() == 0)
}

@Test("본문은 최근 것만 남긴다")
func cachePrune() throws {
    let base = tempCacheRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    var cache = MailCache(root: base)
    cache.maxMessages = 3
    for i in 0..<5 {
        cache.saveMessage(MailMessage(id: "m\(i)", subject: "s", from: nil, receivedDateTime: nil))
        // 수정 시각이 겹치지 않게 조금 기다린다
        Thread.sleep(forTimeInterval: 0.02)
    }
    let files = try FileManager.default.contentsOfDirectory(at: base.appending(path: "messages"), includingPropertiesForKeys: nil)
    #expect(files.count == 3)
    #expect(cache.message(id: "m4") != nil)
    #expect(cache.message(id: "m0") == nil)
}

@Test("오프라인 오류 가르기", arguments: [
    (URLError(.notConnectedToInternet) as Error, true),
    (URLError(.timedOut) as Error, true),
    (URLError(.cannotFindHost) as Error, true),
    (URLError(.badServerResponse) as Error, false),
    (OfflineError.unavailable("보낼") as Error, true),
    (CancellationError() as Error, false),
])
func offlineClassification(_ error: Error, _ expected: Bool) {
    #expect(OfflineError.isOffline(error) == expected)
}

// S-029 깃발, S-031 폴더 계층

@Test("하위 폴더는 부모 바로 아래에 깊이만큼 놓인다")
func folderTree() {
    func f(_ id: String, _ name: String, parent: String? = "root") -> MailFolder {
        var m = MailFolder(id: id, displayName: name)
        m.parentFolderId = parent
        return m
    }
    let list = [f("p", "프로젝트"), f("p2", "2024 견적", parent: "p"), f("in", "Inbox"), f("p1", "2023 견적", parent: "p"),
                f("p21", "최종", parent: "p2"), f("x", "Archive")]
    let tree = FolderOrder.tree(list)
    #expect(tree.map(\.id) == ["in", "x", "p", "p1", "p2", "p21"])
    #expect(tree.map { $0.depth ?? -1 } == [0, 0, 0, 1, 1, 2])
    #expect(tree[0].kind == "inbox" && !tree[0].isEditable)
    #expect(tree[2].isEditable)
    // 하위 폴더 이름이 "Inbox"여도 잘 알려진 폴더가 아니다
    let nested = FolderOrder.tree([f("p", "프로젝트"), f("c", "Inbox", parent: "p")])
    #expect(nested[1].kind == nil)
}

@Test("깃발 모아 보기 요청은 모든 폴더에서 flagged를 찾는다")
func flaggedQuery() {
    let r = GraphQuery.flagged()
    #expect(r.query["$filter"] == "flag/flagStatus eq 'flagged'")
    #expect(r.query["$select"]?.contains("flag") == true)
    #expect(r.query["$orderby"] == nil)
}

@Test("깃발 상태를 읽는다")
func flagDecode() throws {
    let json = #"{"id":"m","flag":{"flagStatus":"flagged"}}"#
    let m = try GraphJSON.decoder().decode(MailMessage.self, from: Data(json.utf8))
    #expect(m.isFlagged)
    let body = try JSONEncoder().encode(["flag": FollowupFlag.notFlagged])
    #expect(String(decoding: body, as: UTF8.self) == #"{"flag":{"flagStatus":"notFlagged"}}"#)
}

// S-033 모든 폴더 검색, S-034 인쇄

@Test("모든 폴더 검색 요청은 /me/messages에 $search를 쓴다")
func searchAllQuery() {
    let r = GraphQuery.searchAll(" 견적 \"서\" ")
    #expect(r.query["$search"] == "\"견적 서\"")
    #expect(r.query["$orderby"] == nil)
    #expect(r.query["$select"]?.contains("parentFolderId") == true)
    #expect(r.headers["ConsistencyLevel"] == "eventual")
}

@Test("인쇄 문서는 CSP를 맨 앞에 두고, 머리글을 이스케이프해 본문 앞에 넣는다")
func printPage() throws {
    let tz = try #require(TimeZone(identifier: "Asia/Seoul"))
    let m = MailMessage(id: "p", subject: "<견적>", from: Recipient(name: "김 & 이", address: "a@x.com"),
                        toRecipients: [Recipient(name: nil, address: "b@x.com")],
                        receivedDateTime: Date(timeIntervalSince1970: 1_714_557_600))
    let html = MailContent.printPage(message: m, body: .init(contentType: "html", content: "<p>본문</p>"),
                                     allowRemote: false, timeZone: tz)
    #expect(html.hasPrefix("<meta http-equiv=\"Content-Security-Policy\""))
    #expect(html.contains("<h1>&lt;견적&gt;</h1>"))
    #expect(html.contains("김 &amp; 이 &lt;a@x.com&gt;"))
    #expect(html.contains("b@x.com"))
    #expect(html.contains("2024년 5월 1일"))
    let head = try #require(html.range(of: "print-head\"><h1>"))
    let body = try #require(html.range(of: "<p>본문</p>"))
    #expect(head.lowerBound < body.lowerBound)
}

@Test("인쇄 머리글은 본문 문서의 <body> 안에, 평문은 이스케이프한 본문 앞에")
func printPageInsideBody() throws {
    let m = MailMessage(id: "p", subject: "제목", from: nil, receivedDateTime: nil)
    let full = MailContent.printPage(message: m, body: .init(contentType: "html",
                                     content: "<html><head><style>p{}</style></head><body class=\"x\"><p>본문</p></body></html>"),
                                     allowRemote: false)
    let bodyTag = try #require(full.range(of: "<body class=\"x\">"))
    let head = try #require(full.range(of: "print-head\"><h1>제목</h1>"))
    #expect(bodyTag.upperBound <= head.lowerBound)
    let plain = MailContent.printPage(message: m, body: .init(contentType: "text", content: "<b>평문</b>"), allowRemote: false)
    #expect(plain.contains("print-head\"><h1>제목</h1>"))
    #expect(plain.contains("&lt;b&gt;평문&lt;/b&gt;"))
}

// S-037 예약 보내기, S-038 회의 초대

@Test("Graph 일정 시각은 UTC 또는 IANA 시간대로 읽는다")
func graphDateTime() {
    #expect(GraphDateTime(dateTime: "2024-05-01T10:00:00.0000000", timeZone: "UTC").date == Date(timeIntervalSince1970: 1_714_557_600))
    #expect(GraphDateTime(dateTime: "2024-05-01T19:00:00", timeZone: "Asia/Seoul").date == Date(timeIntervalSince1970: 1_714_557_600))
}

@Test("회의 초대 메일과 일정을 읽는다")
func meetingDecode() throws {
    let json = """
    {"@odata.type":"#microsoft.graph.eventMessageRequest","id":"m","subject":"회의",
     "event":{"id":"e1","subject":"주간 회의","isAllDay":false,
       "start":{"dateTime":"2024-05-01T01:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2024-05-01T02:00:00.0000000","timeZone":"UTC"},
       "location":{"displayName":"3층 회의실"},"responseStatus":{"response":"notResponded"}}}
    """
    let m = try GraphJSON.decoder().decode(MailMessage.self, from: Data(json.utf8))
    #expect(m.isMeetingRequest)
    let e = try #require(m.event)
    #expect(e.location?.displayName == "3층 회의실")
    #expect(e.response == nil)
    let tz = try #require(TimeZone(identifier: "Asia/Seoul"))
    let when = e.whenText(timeZone: tz)
    #expect(when.contains("10:00") && when.contains("11:00"))
    // 보통 메일은 회의 초대가 아니다
    let plain = try GraphJSON.decoder().decode(MailMessage.self, from: Data(##"{"@odata.type":"#microsoft.graph.message","id":"x"}"##.utf8))
    #expect(!plain.isMeetingRequest)
    #expect(MeetingResponse.tentativelyAccept.path == "tentativelyAccept")
}

@Test("예약 보내기 속성과 프리셋")
func scheduledSend() throws {
    let at = Date(timeIntervalSince1970: 1_714_557_600)
    let body = ScheduledSend.patchBody(sendAt: at)
    let props = try #require(body["singleValueExtendedProperties"] as? [[String: String]])
    #expect(props == [["id": "SystemTime 0x3FEF", "value": "2024-05-01T10:00:00Z"]])

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
    // 2024-05-01(수) 19:00 KST: 오늘 오후 6시는 지났다
    let presets = ScheduledSend.presets(now: at, calendar: cal)
    #expect(presets.map(\.title) == ["내일 오전 9:00", "월요일 오전 9:00"])
    #expect(cal.component(.weekday, from: presets[1].date) == 2)
    // 오전 10시면 오늘 오후 6시가 있다
    let morning = at.addingTimeInterval(-9 * 3_600)
    #expect(ScheduledSend.presets(now: morning, calendar: cal).first?.title == "오늘 오후 6:00")
    #expect(!ScheduledSend.isValid(at.addingTimeInterval(30), now: at))
    #expect(ScheduledSend.isValid(at.addingTimeInterval(120), now: at))
}

@Test("회의 응답 서버 값")
func meetingResponseValues() {
    #expect(MeetingResponse.accept.graphValue == "accepted")
    #expect(MeetingResponse.describe("tentativelyAccepted") == "미정")
    #expect(MeetingResponse.describe("notResponded") == "아직 응답 안 함")
    #expect(MeetingResponse.describe(nil) == "아직 응답 안 함")
}

// S-039 규칙, S-040 자동 응답

@Test("간단한 규칙을 Graph 규칙으로 만든다")
func ruleDraft() throws {
    let draft = RuleDraft(name: "", field: .subject, text: " 견적,  발주 ,", action: .move(folderID: "f1"))
    #expect(draft.words == ["견적", "발주"])
    let rule = draft.rule(sequence: 3)
    #expect(rule.displayName == "견적, 발주")
    #expect(rule.conditions?.subjectContains == ["견적", "발주"])
    #expect(rule.conditions?.senderContains == nil)
    #expect(rule.actions?.moveToFolder == "f1")
    let body = rule.createBody
    #expect(body["sequence"] as? Int == 3)
    #expect((body["conditions"] as? [String: Any])?["subjectContains"] as? [String] == ["견적", "발주"])
    #expect((body["actions"] as? [String: Any])?["moveToFolder"] as? String == "f1")
    #expect(body["id"] == nil)
    #expect(rule.summary { $0 == "f1" ? "프로젝트" : nil } == "제목에 '견적', '발주' 포함 → 프로젝트로 이동")
    #expect(!RuleDraft(name: "x", field: .sender, text: " , ", action: .markRead).isValid)
}

@Test("규칙 목록 JSON을 읽는다")
func ruleDecode() throws {
    let json = #"{"value":[{"id":"r1","displayName":"견적","sequence":1,"isEnabled":true,"conditions":{"senderContains":["a@x.com"]},"actions":{"markAsRead":true,"stopProcessingRules":false}}]}"#
    let list = try GraphJSON.decoder().decode(GraphList<MessageRule>.self, from: Data(json.utf8))
    #expect(list.value.first?.conditions?.senderContains == ["a@x.com"])
    #expect(list.value.first?.summary { _ in nil } == "보낸 사람에 'a@x.com' 포함 → 읽음으로 표시")
}

@Test("자동 응답: 기간이 있으면 scheduled, 글은 HTML로")
func automaticReplies() throws {
    let start = Date(timeIntervalSince1970: 1_714_557_600)
    let a = AutomaticReplies.make(on: true, start: start, end: start.addingTimeInterval(86_400), audience: "all",
                                  internalText: "휴가 중입니다.\n<급한 일>은 팀장에게", externalText: "Out of office")
    #expect(a.status == "scheduled")
    #expect(a.scheduledStartDateTime == GraphDateTime(dateTime: "2024-05-01T10:00:00", timeZone: "UTC"))
    #expect(a.internalReplyMessage == "휴가 중입니다.<br>&lt;급한 일&gt;은 팀장에게")
    #expect(AutomaticReplies.plain(a.internalReplyMessage) == "휴가 중입니다.\n<급한 일>은 팀장에게")
    #expect(AutomaticReplies.make(on: true, start: nil, end: nil, audience: "none", internalText: "", externalText: "").status == "alwaysEnabled")
    #expect(!AutomaticReplies.make(on: false, start: start, end: start, audience: "none", internalText: "", externalText: "").isOn)
    let encoded = try JSONEncoder().encode(a)
    let back = try JSONDecoder().decode(AutomaticReplies.self, from: encoded)
    #expect(back == a)
}

// S-041 필터, S-042 정렬

@Test("서버 필터는 and로 잇고, 날짜 정렬과 함께면 날짜 조건이 맨 앞")
func graphFilterString() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
    var f = MailFilter()
    #expect(f.graphFilter() == nil && !f.isActive)
    f.unread = true
    f.flagged = true
    f.category = "Kim's"
    #expect(f.graphFilter() == "isRead eq false and flag/flagStatus eq 'flagged' and categories/any(c:c eq 'Kim''s')")
    let r = GraphQuery.messageList(search: nil, filter: f.graphFilter(), oldestFirst: false)
    #expect(r.query["$filter"]?.hasPrefix("receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false") == true)
    #expect(r.query["$orderby"] == "receivedDateTime desc")
    f.received = .today
    let now = Date(timeIntervalSince1970: 1_714_557_600) // 2024-05-01 19:00 KST
    #expect(f.graphFilter(now: now, calendar: cal)?.hasPrefix("receivedDateTime ge 2024-04-30T15:00:00Z and ") == true)
    let searching = GraphQuery.messageList(search: "견적", filter: f.graphFilter(), oldestFirst: false)
    #expect(searching.query["$filter"] == nil)
    #expect(f.labels.contains("받은 날짜: 오늘"))
}

@Test("멘션과 받는 사람·참조에 나는 앱에서 거른다")
func clientSideFilter() {
    let me = MailAddress(name: "김준", address: "jyun@corp.com")
    var mention = MailMessage(id: "a", subject: "s", from: nil, toRecipients: [Recipient(name: nil, address: "x@corp.com")],
                              ccRecipients: [Recipient(name: nil, address: "JYUN@corp.com")], receivedDateTime: Date(),
                              bodyPreview: "@김준 확인 부탁드립니다")
    var f = MailFilter()
    f.mentionsMe = true
    #expect(f.matches(mention, me: me, serverFiltered: true))
    mention.bodyPreview = "확인 부탁드립니다"
    #expect(!f.matches(mention, me: me, serverFiltered: true))
    f = MailFilter()
    f.toOrCcMe = true
    #expect(f.matches(mention, me: me, serverFiltered: true))
    f.unread = true
    #expect(f.matches(mention, me: me, serverFiltered: true))       // 서버가 이미 걸렀다
    #expect(!f.matches(mention, me: me, serverFiltered: false))     // isRead 기본값 true
}

@Test("정렬: 날짜, 보낸 사람, 첨부")
func sorting() {
    func m(_ id: String, _ from: String, _ hours: Double, attach: Bool = false) -> MailMessage {
        MailMessage(id: id, subject: id, from: Recipient(name: from, address: "\(id)@x.com"),
                    receivedDateTime: Date(timeIntervalSince1970: 1_714_557_600 - hours * 3_600), hasAttachments: attach)
    }
    let list = [m("1", "박", 3), m("2", "김", 1, attach: true), m("3", "이", 2)]
    #expect(MailSort().apply(list).map(\.id) == ["2", "3", "1"])
    #expect(MailSort(key: .date, descending: false).apply(list).map(\.id) == ["1", "3", "2"])
    #expect(MailSort(key: .date, descending: false).serverOldestFirst)
    #expect(MailSort(key: .sender, descending: false).apply(list).map(\.id) == ["2", "1", "3"])
    #expect(MailSort(key: .attachments, descending: true).apply(list).map(\.id) == ["2", "3", "1"])
}

@Test("본문의 mailto: 링크는 받는 사람과 제목을 채운다")
func mailtoLink() throws {
    let url = try #require(URL(string: "mailto:kim%40corp.com?subject=%EA%B2%AC%EC%A0%81%20%EB%AC%B8%EC%9D%98&body=x"))
    let draft = ComposeDraft.mailto(url)
    #expect(draft.to == "kim@corp.com")
    #expect(draft.subject == "견적 문의")
    #expect(ComposeDraft.mailto(try #require(URL(string: "mailto:a@b.com"))).subject == "")
}

@Test("본문 보기: cid 그림을 data: URI로, 평문은 그대로")
func displayBody() {
    let html = MailMessage.Body(contentType: "html", content: "<img src=\"cid:logo\">")
    let file = FileAttachment(id: "1", name: "logo.png", contentType: "image/png", size: 3, isInline: true,
                              contentId: "logo", contentBytes: "AAAA")
    #expect(MailContent.displayBody(html, attachments: [file])?.content.contains("data:image/png;base64,AAAA") == true)
    let text = MailMessage.Body(contentType: "text", content: "cid:logo")
    #expect(MailContent.displayBody(text, attachments: [file]) == text)
    #expect(MailContent.displayBody(nil, attachments: []) == nil)
}

@Test("스마트 메일상자: 모두/하나라도, 서버 필터, 폴더")
func smartMailbox() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var m = MailMessage(id: "a", subject: "견적서 보냅니다", from: Recipient(name: "김 팀장", address: "Kim@Contoso.com"),
                        receivedDateTime: now.addingTimeInterval(-86_400), hasAttachments: true)
    m.isRead = false
    m.parentFolderId = "AAMkFolder"
    var box = SmartMailbox(name: "견적", conditions: [.init(field: .subject, value: "견적"), .init(field: .unread)])
    #expect(box.matches(m, vips: [], now: now))
    m.isRead = true
    #expect(!box.matches(m, vips: [], now: now))
    box.matchAll = false
    #expect(box.matches(m, vips: [], now: now))
    #expect(box.graphFilter(now: now) == nil)                       // 하나라도: 서버에서 좁히지 않는다

    let recent = SmartMailbox(name: "최근 첨부", conditions: [.init(field: .attachments), .init(field: .receivedWithinDays, value: "3"),
                                                          .init(field: .sender, value: "contoso")])
    #expect(recent.matches(m, vips: [], now: now))
    #expect(recent.graphFilter(now: now)?.hasPrefix("receivedDateTime ge ") == true)
    #expect(recent.graphFilter(now: now)?.contains("hasAttachments eq true") == true)
    #expect(!recent.matches(m, vips: [], now: now.addingTimeInterval(5 * 86_400)))

    let vip = SmartMailbox(name: "VIP", conditions: [.init(field: .vip)])
    #expect(vip.matches(m, vips: ["kim@contoso.com"], now: now))
    #expect(!vip.matches(m, vips: [], now: now))

    let folder = SmartMailbox(name: "폴더", conditions: [.init(field: .folder, value: "AAMkFolder")])
    #expect(folder.serverFolderID == "AAMkFolder")
    #expect(folder.matches(m, vips: [], now: now))
    #expect(!SmartMailbox(name: "폴더", conditions: [.init(field: .folder, value: "aamkfolder")]).matches(m, vips: [], now: now))

    #expect(!SmartMailbox(name: "", conditions: [.init(field: .unread)]).isValid)
    #expect(!SmartMailbox(name: "빈 조건", conditions: [.init(field: .sender, value: " ")]).isValid)
    #expect(!SmartMailbox(name: "일수", conditions: [.init(field: .receivedWithinDays, value: "abc")]).isValid)
}

@Test("VIP와 사이드바 상자 id")
func vipAndVirtualIDs() {
    let vip = VIP(address: " Kim@Contoso.com ", name: "")
    #expect(vip.id == "kim@contoso.com")
    #expect(vip.title == "Kim@Contoso.com")
    let m = MailMessage(id: "a", subject: "s", from: Recipient(name: nil, address: "kim@contoso.com"), receivedDateTime: Date())
    #expect(vip.isSender(of: m))
    #expect(VirtualMailbox(id: VirtualMailbox.id(forVIP: "Kim@Contoso.com")) == .vip(address: "kim@contoso.com"))
    #expect(VirtualMailbox(id: FolderOrder.flaggedID) == .flagged)
    #expect(VirtualMailbox(id: VirtualMailbox.allVIPsID) == .allVIPs)
    let box = SmartMailbox(name: "x", conditions: [])
    #expect(VirtualMailbox(id: box.id) == .smart(id: box.id))
    #expect(VirtualMailbox(id: "inbox") == nil)
    #expect(!VirtualMailbox.isVirtual("AAMkFolder"))
    let saved = LocalMailboxes(vips: [vip], smart: [box])
    let data = try? JSONEncoder().encode(saved)
    #expect(data.flatMap { try? JSONDecoder().decode(LocalMailboxes.self, from: $0) } == saved)
}

@Test("메일 활동 보호: 추적기는 빼고 원격 그림은 대신 받는 주소로")
func trackingProtection() {
    let html = """
    <p><img src="https://cdn.shop.com/hero.jpg" srcset="https://cdn.shop.com/hero@2x.jpg 2x" width="600"></p>
    <img src="https://shop.list-manage.com/track/open.php?u=1" width="600">
    <img src='https://news.example.com/o.png?id=9' width="1" height="1">
    <img src="//cdn.shop.com/logo.png" style="display:none">
    <img src="data:image/png;base64,AAAA">
    <td background="https://cdn.shop.com/bg.png" style="background-image:url('https://cdn.shop.com/bg2.png')">
    <div style="background:url(https://mailtrack.io/trace/mail/1.png)"></div>
    """
    let r = TrackingProtection.rewrite(html: html)
    #expect(r.blocked == 4)        // list-manage, 1×1 픽셀, 숨긴 그림, mailtrack.io
    #expect(r.proxied == 3)        // hero, background 속성, url()
    #expect(!r.html.contains("list-manage") && !r.html.contains("mailtrack") && !r.html.contains("o.png"))
    #expect(!r.html.contains("srcset"))
    #expect(r.html.contains("data:image/png;base64,AAAA"))
    #expect(!r.html.contains("src=\"https://") && !r.html.contains("background=\"https://"))

    let proxy = TrackingProtection.proxyURL(for: URL(string: "https://cdn.shop.com/hero.jpg?w=600&h=300")!)
    #expect(proxy.hasPrefix("fakuku-proxy://image?u="))
    #expect(TrackingProtection.originalURL(from: URL(string: proxy))?.absoluteString == "https://cdn.shop.com/hero.jpg?w=600&h=300")
    #expect(TrackingProtection.originalURL(from: URL(string: "fakuku-proxy://image?u=file%3A%2F%2F%2Fetc%2Fpasswd")) == nil)

    let page = MailContent.page(body: .init(contentType: "html", content: html), remote: .proxied)
    #expect(page.contains("img-src data: fakuku-proxy:;"))
    #expect(!page.contains("list-manage"))
    #expect(MailContent.page(body: .init(contentType: "html", content: html), remote: .blocked).contains("list-manage"))
}

@Test("작성: 회사 도메인 밖의 주소만 알린다")
func externalAddresses() {
    let fields = ["김 <kim@corp.com>, lee@partner.co.kr", "park@SUB.corp.com", "choi@corp.co.kr"]
    #expect(ExternalAddresses.find(in: fields, internalDomains: "@corp.com, @corp.co.kr") == ["lee@partner.co.kr"])
    #expect(ExternalAddresses.find(in: fields, internalDomains: "") == [])
    #expect(ExternalAddresses.domains(" @a.com; b.com ") == ["a.com", "b.com"])
}

@Test("차단된 보낸 사람 규칙")
func blockedSenders() {
    let keep = BlockedSenders.rule(addresses: ["a@x.com", "A@X.com", " b@y.com "], mode: .keep, enabled: true)
    #expect(BlockedSenders.addresses(in: keep) == ["a@x.com", "b@y.com"])
    #expect(BlockedSenders.mode(of: keep) == .keep)
    #expect(keep.actions?.assignCategories == ["차단됨"])
    #expect((keep.createBody["actions"] as? [String: Any])?["assignCategories"] as? [String] == ["차단됨"])
    let trash = BlockedSenders.rule(addresses: ["a@x.com"], mode: .trash, enabled: true)
    #expect(BlockedSenders.mode(of: trash) == .trash)
    #expect(BlockedSenders.isBlockRule(trash))
}

@Test("개별 발송: 자리표시자, CSV, 발송 간격")
func mailMerge() {
    let m = MergeMember(name: "김<철수>", email: "kim@corp.com", fields: ["회사": "A&B"])
    #expect(MailMerge.render("{{이름}}님 ({{ 회사 }}) {{없음}}", for: m, html: true) == "김&lt;철수&gt;님 (A&amp;B) ")
    #expect(MailMerge.render("{{name}} <{{email}}>", for: m, html: false) == "김<철수> <kim@corp.com>")
    #expect(MailMerge.placeholders(in: "{{이름}} {{회사}} {{이름}}") == ["이름", "회사"])

    let csv = "이름,이메일,회사\n홍길동,hong@x.com,\"가나, 다라\"\n잘못,not-an-email,X\n,lee@y.com,\n"
    let r = MailMerge.members(fromCSV: csv)
    #expect(r.members.map(\.email) == ["hong@x.com", "lee@y.com"])
    #expect(r.members.first?.fields["회사"] == "가나, 다라")
    #expect(r.skipped == 1)
    #expect(MailMerge.members(fromCSV: "name;email\nA;a@b.com").members.first?.name == "A")

    let g = MergeGroup(name: "g", members: [MergeMember(name: "a", email: "a@x.com"), MergeMember(name: "A", email: "A@x.com"),
                                            MergeMember(name: "b", email: "bad")])
    #expect(g.sendable.count == 1)

    let p = SendPacing.Preset.careful.pacing
    #expect(p.gap(random: 0) == 60 && p.gap(random: 1) == 120)
    let now = Date()
    let thirty = (0..<30).map { now.addingTimeInterval(-Double($0) * 60) }
    #expect(p.hourlyWait(sentAt: thirty, now: now) > 0)
    #expect(p.hourlyWait(sentAt: Array(thirty.prefix(29)), now: now) == 0)
}

@Test("엑셀 CSV: BOM과 CRLF 줄바꿈, N/A 주소는 건너뛴다")
func mergeCSVWindowsLineEndings() {
    let csv = "\u{FEFF}이름,회사,직급,이메일,Mobile\r\nketevani,dental depo,sales,dentaldepoddg@gmail.com,+995\r\n"
        + "madina,unique dental,dentist,N/A,\r\nShakil Kamal,Gensmile,Oral Surgeon,Shakil817@hotmail.com,0044"
    let r = MailMerge.members(fromCSV: csv)
    #expect(r.members.map(\.email) == ["dentaldepoddg@gmail.com", "Shakil817@hotmail.com"])
    #expect(r.members.first?.name == "ketevani")
    #expect(r.members.first?.fields["회사"] == "dental depo")
    #expect(r.members.last?.fields["Mobile"] == "0044")
    #expect(r.skipped == 1)
}

@Test("깃발 색 상자 id와 메일 열쇠")
func flagColors() {
    #expect(VirtualMailbox(id: VirtualMailbox.id(for: .purple)) == .flagColor(.purple))
    #expect(VirtualMailbox(id: "__flag:pink") == nil)
    #expect(VirtualMailbox.isVirtual(VirtualMailbox.id(for: .red)))
    var m = MailMessage(id: "graph-id", subject: "s", from: nil, receivedDateTime: Date())
    #expect(FlagColor.key(for: m) == "graph-id")
    m.internetMessageId = "<abc@x>"
    #expect(FlagColor.key(for: m) == "<abc@x>")
}

@Test("수신 거부 헤더 읽기")
func unsubscribeHeader() {
    let both = Unsubscribe.from(headers: [
        InternetHeader(name: "List-Unsubscribe", value: "<mailto:off@news.com?subject=%EC%88%98%EC%8B%A0%20%EA%B1%B0%EB%B6%80>, <https://news.com/u?id=1>"),
        InternetHeader(name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click"),
    ])
    #expect(both?.web?.absoluteString == "https://news.com/u?id=1")
    #expect(both?.oneClick == true)
    #expect(both?.mailtoParts?.to == "off@news.com")
    #expect(both?.mailtoParts?.subject == "수신 거부")
    #expect(Unsubscribe.from(headers: [InternetHeader(name: "Subject", value: "x")]) == nil)
    #expect(Unsubscribe.from(headers: [InternetHeader(name: "list-unsubscribe", value: "<mailto:a@b.com>")])?.oneClick == false)
}

@Test("가져온 HTML 문서에는 </body> 앞에 덧붙인다")
func appendToBody() {
    #expect(MailMerge.appendToBody("<html><body><p>x</p></BODY></html>", "<p>F</p>") == "<html><body><p>x</p><p>F</p></BODY></html>")
    #expect(MailMerge.appendToBody("<p>x</p>", "<p>F</p>") == "<p>x</p><p>F</p>")
}

@Test("Exchange가 나눈 대화도 답장 제목이면 한 줄로, 보낸 편지함의 내 답장도 센다")
func groupConversationsBySubjectAndRelated() {
    func m(_ id: String, _ conv: String, _ subject: String, _ hours: Double, from: String = "kim@x.com") -> MailMessage {
        MailMessage(id: id, conversationId: conv, subject: subject, from: Recipient(name: nil, address: from),
                    receivedDateTime: Date(timeIntervalSince1970: 1_714_557_600 - hours * 3_600))
    }
    let inbox = [
        m("1", "A", "견적 요청", 5),
        m("2", "B", "RE: 견적 요청", 1),          // 바깥 메일 앱 답장: Exchange가 다른 대화로 나눔
        m("3", "C", "안녕하세요", 2),
        m("4", "D", "안녕하세요", 3),             // 답장이 아닌 같은 제목: 합치지 않는다
    ]
    let sent = [m("s1", "A", "회신: 견적 요청", 4, from: "me@corp.com"), m("s2", "Z", "다른 건", 6, from: "me@corp.com")]
    let groups = Conversations.group(inbox, related: sent)
    #expect(groups.count == 3)
    let quote = groups.first { $0.messageIDs.contains("1") }
    #expect(quote?.messageIDs == ["2", "1"])
    #expect(quote?.count == 3)
    #expect(quote?.participants(me: "me@corp.com").contains("나") == true)
    #expect(Conversations.normalizedSubject("RE: FW: 회신: Re[2]:  견적   요청").base == "견적 요청")
    #expect(Conversations.normalizedSubject("견적").wasReply == false)
}

// S-056 수락한 회의를 맥 캘린더에

@Test("맥 캘린더 일정: 시각 있는 회의는 그 시각, 제목·장소·표시")
func calendarEntryTimed() throws {
    let event = MailEvent(id: "AAMk+abc/1=", subject: "  주간 회의 ",
                          start: GraphDateTime(dateTime: "2026-11-05T01:00:00.0000000", timeZone: "UTC"),
                          end: GraphDateTime(dateTime: "2026-11-05T02:00:00.0000000", timeZone: "UTC"),
                          location: "3층 회의실")
    let entry = try #require(CalendarEntry(event: event))
    #expect(entry.title == "주간 회의")
    #expect(entry.start == ISO8601DateFormatter().date(from: "2026-11-05T01:00:00Z"))
    #expect(entry.end.timeIntervalSince(entry.start) == 3600)
    #expect(!entry.isAllDay && entry.location == "3층 회의실")
    #expect(entry.marker.absoluteString.hasPrefix("fakuku-meeting://event/"))
    #expect(entry.marker == CalendarEntry.marker(eventID: "AAMk+abc/1="))
    #expect(entry.isSame(title: "주간 회의", start: entry.start.addingTimeInterval(30), isAllDay: false))
    #expect(!entry.isSame(title: "다른 회의", start: entry.start, isAllDay: false))
    #expect(!entry.isSame(title: "주간 회의", start: entry.start.addingTimeInterval(3600), isAllDay: false))
}

@Test("맥 캘린더 일정: 종일 회의는 날짜만 (시간대로 하루가 밀리지 않게)")
func calendarEntryAllDay() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    let event = MailEvent(id: "x", subject: nil,
                          start: GraphDateTime(dateTime: "2026-11-05T00:00:00.0000000", timeZone: "UTC"),
                          end: GraphDateTime(dateTime: "2026-11-07T00:00:00.0000000", timeZone: "UTC"), isAllDay: true)
    let entry = try #require(CalendarEntry(event: event, fallbackTitle: "워크숍", calendar: cal))
    #expect(entry.title == "워크숍" && entry.isAllDay)
    #expect(cal.component(.day, from: entry.start) == 5 && cal.component(.hour, from: entry.start) == 0)
    #expect(cal.component(.day, from: entry.end) == 6)   // 이틀짜리: 6일 끝까지
    #expect(CalendarEntry(event: MailEvent(id: "y", subject: "a", start: nil, end: nil)) == nil)
}

@Test("맥 캘린더 일정: 주최자가 시각·제목·장소를 바꾸면 앱이 넣은 일정을 고친다")
func calendarEntryNeedsUpdate() throws {
    let event = MailEvent(id: "z", subject: "주간 회의",
                          start: GraphDateTime(dateTime: "2026-11-05T01:00:00.0000000", timeZone: "UTC"),
                          end: GraphDateTime(dateTime: "2026-11-05T02:00:00.0000000", timeZone: "UTC"),
                          location: "3층 회의실")
    let e = try #require(CalendarEntry(event: event))
    #expect(!e.needsUpdate(title: " 주간 회의", start: e.start, end: e.end, isAllDay: false, location: "3층 회의실 "))
    #expect(e.needsUpdate(title: "주간 회의", start: e.start.addingTimeInterval(-3600), end: e.end, isAllDay: false, location: "3층 회의실"))
    #expect(e.needsUpdate(title: "주간 회의", start: e.start, end: e.end.addingTimeInterval(1800), isAllDay: false, location: "3층 회의실"))
    #expect(e.needsUpdate(title: "주간 회의", start: e.start, end: e.end, isAllDay: false, location: "5층"))
    #expect(e.needsUpdate(title: "예전 제목", start: e.start, end: e.end, isAllDay: false, location: "3층 회의실"))
}

// S-057 Siri가 읽어 주는 글

@Test("Siri: 최근 메일은 보낸 사람, 제목, 본문 앞부분")
func speechLatest() {
    let m = MailMessage(id: "1", subject: "견적 요청", from: Recipient(name: "김 대리", address: "kim@ex.com"),
                        receivedDateTime: Date(), bodyPreview: "안녕하세요,\n  견적을   부탁드립니다." + String(repeating: "가", count: 300))
    let text = MailSpeech.latest(m)
    #expect(text.hasPrefix("김 대리님이 보낸 메일입니다. 제목은 견적 요청입니다. 안녕하세요, 견적을 부탁드립니다."))
    #expect(text.hasSuffix("…") && text.count < 260)
}

@Test("Siri: 읽지 않은 메일 요약은 다섯 통까지, 나머지는 '외 N통'")
func speechUnread() {
    let list = (1...7).map { i in
        MailMessage(id: "\(i)", subject: "제목\(i)", from: Recipient(name: "사람\(i)", address: "p\(i)@ex.com"),
                    receivedDateTime: Date())
    }
    let text = MailSpeech.unreadSummary(list, total: 9)
    #expect(text.hasPrefix("읽지 않은 메일 9통. 1. 사람1, 제목1."))
    #expect(text.contains("5. 사람5, 제목5.") && !text.contains("사람6"))
    #expect(text.hasSuffix("외 4통."))
    #expect(MailSpeech.unreadSummary([], total: 0) == "읽지 않은 메일이 없습니다.")
}

// S-058 이메일만으로 로그인 (멀티 테넌트 앱)

@Test("로그인 주소: 이메일을 주면 login_hint로 채우고, 없으면 계정 고르기")
func authorizeHint() throws {
    let redirect = OAuth.redirectURI(bundleID: "com.fakukulab.fakukumail")
    let hinted = try #require(OAuth.authorizeURL(tenant: "", clientID: "cid", redirectURI: redirect,
                                                 challenge: "c", state: "s", loginHint: " kim@corp.com "))
    let items = URLComponents(url: hinted, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.first { $0.name == "login_hint" }?.value == "kim@corp.com")
    #expect(!items.contains { $0.name == "prompt" })
    #expect(hinted.absoluteString.hasPrefix("https://login.microsoftonline.com/common/"))
    let plain = try #require(OAuth.authorizeURL(tenant: "", clientID: "cid", redirectURI: redirect, challenge: "c", state: "s"))
    #expect(URLComponents(url: plain, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prompt" }?.value == "select_account")
}

@Test("관리자 승인: 주소와 오류 알아보기")
func adminConsent() throws {
    let url = try #require(OAuth.adminConsentURL(tenant: "", clientID: "cid", redirectURI: "msauth.x://auth"))
    #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/organizations/v2.0/adminconsent?"))
    #expect(url.absoluteString.contains("client_id=cid"))
    #expect(OAuth.needsAdminConsent("AADSTS65001: The user or administrator has not consented to use the application"))
    #expect(OAuth.needsAdminConsent("AADSTS90094: Admin approval required"))
    #expect(!OAuth.needsAdminConsent("AADSTS50126: Invalid username or password"))
}

// 배포 전 점검: 첨부 id의 / + 를 경로에서 깨지지 않게
@Test func graphPathEncodesSlashAndPlus() {
    #expect(GraphPath.segment("AAMkAD/x+y=") == "AAMkAD%2Fx%2By=")
    #expect(GraphPath.segment("inbox") == "inbox")
    #expect(URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages/" + GraphPath.segment("a/b") + "/$value")?.percentEncodedPath
            == "/v1.0/me/messages/a%2Fb/$value")
    #expect(GraphPath.segment("받은") == "%EB%B0%9B%EC%9D%80")
}
