import Foundation
import Testing
@testable import ExchangeMailKit

// M24 2단계: SMTP 보내기

private let mime = Data("""
From: =?utf-8?B?6rmA?= <me@icloud.com>\r
To: "Lee, Jin" <lee@example.com>, park@example.com\r
Cc: kim@example.com\r
Bcc: secret@example.com,\r
 hidden@example.com\r
Message-ID: <abc@icloud.com>\r
Subject: Hi\r
\r
.leading dot\r
body\r
""".utf8)

@Test func smtpEnvelopeReadsAllRecipients() {
    let e = SMTP.envelope(mime)
    #expect(e.from == "me@icloud.com")
    #expect(e.recipients == ["lee@example.com", "park@example.com", "kim@example.com", "secret@example.com", "hidden@example.com"])
    #expect(SMTP.messageID(mime) == "<abc@icloud.com>")
}

@Test func smtpRemovesBccHeader() {
    let text = String(decoding: SMTP.removingBcc(mime), as: UTF8.self)
    #expect(!text.contains("Bcc:"))
    #expect(!text.contains("hidden@example.com"))
    #expect(text.contains("Cc: kim@example.com"))
    #expect(text.hasSuffix(".leading dot\r\nbody\r"))
}

@Test func smtpDotStuffsAndTerminates() {
    let payload = String(decoding: SMTP.dataPayload(Data("a\n.b\r\nc".utf8)), as: UTF8.self)
    #expect(payload == "a\r\n..b\r\nc\r\n.\r\n")
}

@Test func smtpParsesMultilineReply() {
    #expect(SMTP.reply(from: ["250-smtp.mail.me.com", "250-STARTTLS"]) == nil)
    let r = SMTP.reply(from: ["250-smtp.mail.me.com", "250 AUTH PLAIN"])
    #expect(r?.code == 250)
    #expect(r?.lines == ["smtp.mail.me.com", "AUTH PLAIN"])
    #expect(SMTP.plainAuth(user: "a", password: "b") == Data("\u{0}a\u{0}b".utf8).base64EncodedString())
}
