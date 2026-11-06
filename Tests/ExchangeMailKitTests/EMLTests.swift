import Foundation
import Testing
@testable import ExchangeMailKit

// 1.1 .eml 파일 열기: 읽고, 답장·전체 답장·전달·새 메시지로 편집. mailto: 링크 (기본 이메일 앱).

private let eml = """
From: =?utf-8?B?6rmA7Lyc7J20?= <kim@example.com>\r
To: me@corp.com, Lee <lee@corp.com>\r
Cc: park@corp.com\r
Reply-To: list@example.com\r
Subject: =?utf-8?Q?=ED=9A=8C=EC=9D=98?=\r
Date: Mon, 2 Nov 2026 09:30:00 +0900\r
Message-ID: <abc@example.com>\r
References: <root@example.com>\r
MIME-Version: 1.0\r
Content-Type: multipart/mixed; boundary="b1"\r
\r
--b1\r
Content-Type: text/html; charset=utf-8\r
\r
<html><body><p>Hello</p><script>alert(1)</script></body></html>\r
--b1\r
Content-Type: application/pdf; name="quote.pdf"\r
Content-Disposition: attachment; filename="quote.pdf"\r
Content-Transfer-Encoding: base64\r
\r
JVBERi0=\r
--b1--\r
"""

private var mail: ArchivedMail { MailArchive.parse(Data(eml.utf8)) }

@Test("eml의 Message-ID, References, Reply-To를 읽는다")
func emlThreadHeaders() {
    #expect(mail.messageID == "<abc@example.com>")
    #expect(mail.references == ["<root@example.com>"])
    #expect(mail.replyTo == "list@example.com")
}

@Test("eml 답장: Reply-To로, 같은 대화로 묶이게, 스크립트는 인용하지 않는다")
func emlReply() {
    let d = EMLMessage.draft(kind: .reply, mail: mail, myAddress: "me@corp.com")
    #expect(d.to == "list@example.com")
    #expect(d.subject == "RE: 회의")
    #expect(d.inReplyTo == "<abc@example.com>")
    #expect(d.references == ["<root@example.com>", "<abc@example.com>"])
    #expect(d.quoteHTML.contains("Hello"))
    #expect(!d.quoteHTML.contains("<script"))
    #expect(d.forwardAttachmentsFrom == nil)
}

@Test("eml 전체 답장: 받는 사람·참조에서 나는 빼고, Reply-To가 받는 사람")
func emlReplyAll() {
    let d = EMLMessage.draft(kind: .replyAll, mail: mail, myAddress: "me@corp.com")
    #expect(d.to == "list@example.com")
    #expect(d.cc.contains("lee@corp.com") && d.cc.contains("park@corp.com"))
    #expect(!d.cc.contains("me@corp.com"))
}

@Test("eml 전달: FW: 제목, 받는 사람 없음, 서버 첨부를 찾지 않는다")
func emlForward() {
    let d = EMLMessage.draft(kind: .forward, mail: mail, myAddress: "me@corp.com")
    #expect(d.subject == "FW: 회의")
    #expect(d.to.isEmpty)
    #expect(d.quoteHTML.contains("data-quote=\"forward\""))
    #expect(d.forwardAttachmentsFrom == nil)
}

@Test("eml 새 메시지로 편집: 받는 사람·참조·제목·본문을 그대로")
func emlEditAsNew() {
    let d = EMLMessage.draft(kind: .new, mail: mail, myAddress: nil)
    #expect(d.to.contains("me@corp.com") && d.to.contains("lee@corp.com"))
    #expect(d.cc == "park@corp.com")
    #expect(d.subject == "회의")
    #expect(d.bodyHTML?.contains("Hello") == true)
    #expect(d.bodyHTML?.contains("<body") == false)
}

@Test("글자만 있는 eml은 줄을 지켜 인용한다")
func emlPlainQuote() {
    let plain = MailArchive.parse(Data("From: a@b.com\r\nSubject: x\r\n\r\n1 < 2\r\nline\r\n".utf8))
    let html = EMLMessage.bodyHTML(plain)
    #expect(html.hasPrefix("<pre"))
    #expect(html.contains("1 &lt; 2"))
}

@Test("첨부된 메일을 알아본다")
func emlIsMail() {
    #expect(EMLMessage.isMail(name: "Meeting.EML", contentType: nil))
    #expect(EMLMessage.isMail(name: "forwarded", contentType: "message/rfc822"))
    #expect(!EMLMessage.isMail(name: "quote.pdf", contentType: "application/pdf"))
}

@Test("mailto: 링크의 받는 사람 여럿, 참조, 숨은 참조, 본문")
func mailtoFull() throws {
    let url = try #require(URL(string: "mailto:a@b.com,c@d.com?cc=e@f.com&bcc=g@h.com&subject=Hi&body=line1%0D%0Aline%3C2%3E"))
    let d = ComposeDraft.mailto(url)
    #expect(d.to == "a@b.com,c@d.com")
    #expect(d.cc == "e@f.com")
    #expect(d.bcc == "g@h.com")
    #expect(d.subject == "Hi")
    #expect(d.bodyTextHTML == "<div>line1</div><div>line&lt;2&gt;</div>")
    #expect(ComposeDraft.mailto(try #require(URL(string: "mailto:?to=x@y.com"))).to == "x@y.com")
    #expect(ComposeDraft.mailto(try #require(URL(string: "mailto:a@b.com"))).bodyTextHTML == nil)
}
