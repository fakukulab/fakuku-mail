import Foundation
import Testing
@testable import ExchangeMailKit

// M24 IMAP: 서버 응답 해석

private func data(_ s: String) -> Data { Data(s.utf8) }

@Test func imapSplitsResponsesWithLiterals() throws {
    let buffer = data("* 1 FETCH (UID 7 BODY[] {5}\r\nHello)\r\nA1 OK done\r\n* 2 EXI")
    let first = try #require(IMAP.nextResponse(in: buffer))
    #expect(String(decoding: first.response, as: UTF8.self) == "* 1 FETCH (UID 7 BODY[] {5}\r\nHello)\r\n")
    let second = try #require(IMAP.nextResponse(in: first.rest))
    #expect(IMAP.parse(second.response) == .tagged(tag: "A1", status: "OK", text: "done"))
    // 아직 끝나지 않은 줄
    #expect(IMAP.nextResponse(in: second.rest) == nil)
    // 덩어리가 다 오지 않았으면 기다린다
    #expect(IMAP.nextResponse(in: data("* 1 FETCH (BODY[] {10}\r\nabc")) == nil)
}

@Test func imapParsesFetch() throws {
    let raw = "* 3 FETCH (UID 42 FLAGS (\\Seen \\Flagged) INTERNALDATE \"02-Nov-2026 09:30:00 +0900\" "
        + "ENVELOPE (\"Mon, 2 Nov 2026 09:30:00 +0900\" \"=?utf-8?B?7ZqM7J2Y?=\" "
        + "((\"Kim\" NIL \"kim\" \"example.com\")) NIL NIL ((NIL NIL \"me\" \"icloud.com\")) NIL NIL NIL \"<a@b>\") "
        + "BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 3 1 NIL NIL NIL)(\"APPLICATION\" \"PDF\" (\"NAME\" \"a.pdf\") NIL NIL \"BASE64\" 10 NIL (\"attachment\" (\"FILENAME\" \"a.pdf\")) NIL) \"MIXED\"))\r\n"
    guard case .untagged(let values) = IMAP.parse(data(raw)) else { Issue.record("not untagged"); return }
    let items = try #require(IMAP.fetchItems(values))
    let m = try #require(IMAP.summary(items, account: "acc", path: "INBOX"))
    #expect(m.id == "imap:acc:INBOX#42")
    #expect(m.subject == "회의")
    #expect(m.from?.emailAddress.address == "kim@example.com")
    #expect(m.from?.emailAddress.name == "Kim")
    #expect(m.toRecipients?.first?.emailAddress.address == "me@icloud.com")
    #expect(m.isRead == true)
    #expect(m.flag == .flagged)
    #expect(m.hasAttachments == true)
    #expect(m.internetMessageId == "<a@b>")
    #expect(m.receivedDateTime != nil)
    #expect(m.parentFolderId == "imap:acc:INBOX")
}

@Test func imapParsesListAndKinds() throws {
    guard case .untagged(let v) = IMAP.parse(data("* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Messages\"\r\n")) else {
        Issue.record("not untagged"); return
    }
    let entry = try #require(IMAP.listEntry(v))
    #expect(entry.path == "Sent Messages")
    #expect(entry.delimiter == "/")
    #expect(IMAP.kind(of: entry) == "sentitems")
    #expect(IMAP.kind(of: .init(flags: [], delimiter: "/", path: "Deleted Messages")) == "deleteditems")
    #expect(IMAP.kind(of: .init(flags: [], delimiter: "/", path: "INBOX")) == "inbox")
    #expect(IMAP.kind(of: .init(flags: ["\\junk"], delimiter: "/", path: "x")) == "junkemail")
    #expect(IMAP.kind(of: .init(flags: [], delimiter: "/", path: "Work")) == nil)
}

@Test func imapFolderNamesRoundTrip() {
    #expect(IMAP.decodeFolderName("&1VyuAA-") == "한글")
    #expect(IMAP.encodeFolderName("한글") == "&1VyuAA-")
    #expect(IMAP.decodeFolderName("A&-B") == "A&B")
    #expect(IMAP.encodeFolderName("A&B") == "A&-B")
    for name in ["보낸 편지함", "Work/2026", "프로젝트 & 회의"] {
        #expect(IMAP.decodeFolderName(IMAP.encodeFolderName(name)) == name)
    }
}

@Test func imapIDsRoundTrip() throws {
    let id = IMAP.messageID(account: "a1", path: "Work:Q#1 100%", uid: 9)
    let parsed = try #require(IMAP.parseID(id))
    #expect(parsed.account == "a1")
    #expect(parsed.path == "Work:Q#1 100%")
    #expect(parsed.uid == 9)
    let folder = try #require(IMAP.parseID(IMAP.folderID(account: "a1", path: "INBOX")))
    #expect(folder.uid == nil)
    #expect(IMAP.parseID("AAMk123") == nil)
}

@Test func imapQuotes() {
    #expect(IMAP.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
}

@Test func imapDetailFillsBody() {
    let mime = data("Message-ID: <x@y>\r\nSubject: Hi\r\nContent-Type: multipart/mixed; boundary=\"b\"\r\n\r\n--b\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>안녕</p>\r\n--b\r\nContent-Type: text/plain; name=\"n.txt\"\r\nContent-Disposition: attachment; filename=\"n.txt\"\r\n\r\nnote\r\n--b--\r\n")
    let base = MailMessage(id: "imap:a:INBOX#1", subject: "Hi", from: nil, receivedDateTime: nil)
    let (m, files) = IMAP.detail(base, mime: mime)
    #expect(m.body?.isHTML == true)
    #expect(m.body?.content.contains("안녕") == true)
    #expect(files.map(\.name) == ["n.txt"])
    #expect(files.first?.data.map { String(decoding: $0, as: UTF8.self).hasPrefix("note") } == true)
    #expect(m.internetMessageHeaders?.contains { $0.name == "Message-Id" && $0.value == "<x@y>" } == true)
}

@Test func icloudConfig() {
    let c = IMAPAccountConfig.icloud(email: "jane@icloud.com", name: "Jane")
    #expect(c.username == "jane")
    #expect(c.imapHost == "imap.mail.me.com")
    #expect(c.smtpPort == 587 && c.smtpStartTLS)
    #expect(IMAPAccountConfig.icloud(email: "jane@custom.com", name: "J").username == "jane@custom.com")
}

@Test func imapScanWaitsForLiteralSize() {
    let head = data("* 1 FETCH (BODY[] {10}\r\nabc")
    // 덩어리가 다 오려면 줄 끝 뒤로 10바이트가 필요하다
    #expect(IMAP.scan(head, from: 0) == .incomplete(needed: head.count - 3 + 10))
    let full = head + data("defghij)\r\nA2 OK\r\n")
    guard case .complete(let end) = IMAP.scan(full, from: 0) else { Issue.record("incomplete"); return }
    #expect(IMAP.scan(full, from: end) == .complete(end: full.count))
}

@Test func imapThreadsByReferences() throws {
    #expect(IMAP.threadRoot(references: "<A@x> <b@x>", inReplyTo: "<b@x>", messageID: "<c@x>") == "<a@x>")
    #expect(IMAP.threadRoot(references: nil, inReplyTo: "<b@x>", messageID: "<c@x>") == "<b@x>")
    #expect(IMAP.threadRoot(references: nil, inReplyTo: nil, messageID: "<c@x>") == "<c@x>")
    let id = IMAP.conversationID(account: "acc", root: "<a@x>")
    let parsed = try #require(IMAP.parseConversationID(id))
    #expect(parsed.account == "acc" && parsed.root == "<a@x>")

    // 목록 FETCH의 머리글 몇 줄로 대화 id를 정한다
    let raw = "* 1 FETCH (UID 9 ENVELOPE (NIL \"Re: Hi\" NIL NIL NIL NIL NIL NIL \"<a@x>\" \"<c@x>\") "
        + "BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO)] {41}\r\nReferences: <a@x>\r\nIn-Reply-To: <a@x>\r\n\r\n)\r\n"
    guard case .untagged(let values) = IMAP.parse(data(raw)) else { Issue.record("not untagged"); return }
    let items = try #require(IMAP.fetchItems(values))
    #expect(IMAP.summary(items, account: "acc", path: "INBOX")?.conversationId == id)
    #expect(IMAP.bodySection(items) == nil)
}
