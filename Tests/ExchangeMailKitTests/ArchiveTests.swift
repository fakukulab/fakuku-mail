import Foundation
import Testing
@testable import ExchangeMailKit

// S-053 메일상자 내보내기·보관한 메일 열기

private let sample = """
From: =?utf-8?B?6rmA7Lyc7J20?= <kim@example.com>\r
To: me@example.com\r
Subject: =?utf-8?Q?=ED=9A=8C=EC=9D=98?= =?utf-8?Q?_=EC=9E=90=EB=A3=8C?=\r
Date: Mon, 2 Nov 2026 09:30:00 +0900\r
MIME-Version: 1.0\r
Content-Type: multipart/mixed; boundary="b1"\r
\r
--b1\r
Content-Type: multipart/alternative; boundary="b2"\r
\r
--b2\r
Content-Type: text/plain; charset=utf-8\r
Content-Transfer-Encoding: quoted-printable\r
\r
=EC=95=88=EB=85=95=ED=95=98=EC=84=B8=EC=9A=94\r
From the team\r
--b2\r
Content-Type: text/html; charset=utf-8\r
Content-Transfer-Encoding: base64\r
\r
PHA+7JWI64WVPC9wPjxpbWcgc3JjPSJjaWQ6bG9nbyI+\r
--b2--\r
--b1\r
Content-Type: image/png\r
Content-ID: <logo>\r
Content-Transfer-Encoding: base64\r
\r
iVBORw0KGgo=\r
--b1\r
Content-Type: application/pdf; name*=utf-8''%EB%B3%B4%EA%B3%A0%EC%84%9C.pdf\r
Content-Disposition: attachment; filename*=utf-8''%EB%B3%B4%EA%B3%A0%EC%84%9C.pdf\r
Content-Transfer-Encoding: base64\r
\r
JVBERi0=\r
--b1--\r

"""

@Test("MIME 메일 하나를 읽는다: 인코딩된 제목·이름, 본문, 그림, 한글 파일 이름")
func archiveParse() {
    let mail = MailArchive.parse(Data(sample.utf8))
    #expect(mail.subject == "회의 자료")
    #expect(mail.from.hasPrefix("김켜이"))
    #expect(mail.text?.hasPrefix("안녕하세요") == true)
    #expect(mail.html == "<p>안녕</p><img src=\"cid:logo\">")
    #expect(mail.attachments.count == 2)
    #expect(mail.attachments[0].isInline && mail.attachments[0].contentID == "logo")
    #expect(mail.attachments[1].name == "보고서.pdf" && !mail.attachments[1].isInline)
    #expect(mail.attachments[1].data == Data("%PDF-".utf8))
    #expect(mail.date == ISO8601DateFormatter().date(from: "2026-11-02T00:30:00Z"))
    #expect(MailArchive.inlineImages(mail)?.contains("data:image/png;base64,iVBORw0KGgo=") == true)
}

@Test("mbox로 쓰고 다시 읽으면 메일이 그대로다 (본문의 From 줄 포함)")
func mboxRoundTrip() {
    let second = "From: b@example.com\r\nSubject: 둘째\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nFrom here on\r\n>From quoted\r\n"
    var mbox = MailArchive.mboxEntry(Data(sample.utf8), date: nil)
    mbox.append(MailArchive.mboxEntry(Data(second.utf8), date: nil))
    let text = String(decoding: mbox, as: UTF8.self)
    #expect(text.hasPrefix("From FAKUKU-Mail "))
    #expect(text.contains("\n>From here on\n") && text.contains("\n>>From quoted\n"))
    let parts = MailArchive.split(mbox)
    #expect(parts.count == 2)
    let mail = MailArchive.parse(parts[1])
    #expect(mail.subject == "둘째")
    #expect(mail.text == "From here on\n>From quoted\n")
    #expect(MailArchive.parse(parts[0]).attachments.count == 2)
}

@Test("eml 파일 하나와 UTF-8 그대로 쓴 머리글, EUC-KR 본문")
func emlAndCharsets() {
    let euc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
    var raw = Data("Subject: 그대로 쓴 제목\r\nContent-Type: text/plain; charset=euc-kr\r\n\r\n".utf8)
    raw.append("한글 본문".data(using: euc)!)
    let list = MailArchive.read(raw)
    #expect(list.count == 1)
    #expect(list[0].subject == "그대로 쓴 제목")
    #expect(list[0].text == "한글 본문")
    #expect(MailArchive.read(Data()).isEmpty)
}

@Test("목록 글: 보낸 사람 이름, 본문 앞부분")
func archiveListText() {
    #expect(MailArchive.displayName("\"김 대리\" <kim@example.com>") == "김 대리")
    #expect(MailArchive.displayName("<kim@example.com>") == "kim@example.com")
    var mail = MailArchive.parse(Data("Subject: x\r\nContent-Type: text/html\r\n\r\n<style>p{}</style><p>안녕&nbsp;하세요</p>\r\n".utf8))
    #expect(MailArchive.preview(mail) == "안녕 하세요")
    mail.text = "  첫 줄\n둘째 줄 "
    #expect(MailArchive.preview(mail) == "첫 줄 둘째 줄")
}

// S-054 화면 글자 번역 키

@Test("L(): 끼워 넣은 값은 키에서 %@, 원문의 %는 %%, 번역이 없으면 원문")
func localizationKeys() {
    let n = 3
    let interpolated: Loc = "메시지 \(n)개, 읽지 않음 \(Optional(1) ?? 0)개"
    #expect(interpolated.key == "메시지 %@개, 읽지 않음 %@개")
    #expect(interpolated.args == ["3", "1"])
    let percent: Loc = "100% 완료"
    #expect(percent.key == "100%% 완료")
    #expect(L("100% 완료") == "100% 완료")
    #expect(L("메일 \(n)통") == "메일 3통")
    #expect(L("\(Date(timeIntervalSince1970: 0), format: .iso8601.year())년") == "1970년")
    #expect(AppLanguage.isKorean)
}

@Test("옛 Mac 줄 끝(CR만)과 앞의 빈 줄, 빈 줄 없는 구분 줄도 메일마다 나눈다")
func mboxOldMacLineEndings() {
    let lf = """
    From kim@example.com Mon Dec  4 10:00:00 2006
    From: Kim <kim@example.com>
    Subject: First
    Content-Type: text/plain

    Hello
    From lee@example.com Tue Dec  5 11:30:00 2006
    From: Lee <lee@example.com>
    Subject: Second

    World

    """
    let cr = "\n\n" + lf.replacingOccurrences(of: "\n", with: "\r")
    let list = MailArchive.read(Data(cr.utf8))
    #expect(list.count == 2)
    #expect(Set(list.map(\.subject)) == ["First", "Second"])
    #expect(list.first { $0.subject == "First" }?.text?.hasPrefix("Hello") == true)
    #expect(list.first { $0.subject == "Second" }?.from.hasPrefix("Lee") == true)
}

@Test("맥 Mail의 .emlx: 길이 줄 뒤의 원본만")
func emlxMessage() {
    let mime = "Subject: Hi\r\n\r\nBody\r\n"
    let emlx = "\(mime.utf8.count)\n" + mime + "<?xml version=\"1.0\"?><plist></plist>"
    let mail = MailArchive.parse(MailArchive.emlxMessage(Data(emlx.utf8)))
    #expect(mail.subject == "Hi")
    #expect(mail.text == "Body\n")
}

@Test("메일 파일 검색: HTML 본문, 첨부 이름, 낱말 여러 개")
func archiveSearch() {
    let mail = MailArchive.parse(Data(sample.utf8))
    let text = MailArchive.searchText(mail)
    #expect(MailArchive.matches(text, query: "안녕"))           // HTML·평문 본문
    #expect(MailArchive.matches(text, query: "보고서.pdf"))     // 첨부 이름
    #expect(MailArchive.matches(text, query: "회의 KIM"))       // 제목 + 보낸 사람, 대소문자 무시
    #expect(!MailArchive.matches(text, query: "회의 없는말"))
    #expect(!MailArchive.matches(text, query: "  "))
}

@Test("목록 색인: 메일마다 위치와 요약, 그 위치에서 한 통만 다시 읽는다")
func archiveIndex() throws {
    let second = "From: b@example.com\r\nSubject: 둘째\r\nDate: Tue, 3 Nov 2026 09:00:00 +0900\r\n\r\nFrom here on\r\n"
    var mbox = MailArchive.mboxEntry(Data(sample.utf8), date: nil)
    mbox.append(MailArchive.mboxEntry(Data(second.utf8), date: nil))
    #expect(ArchiveIndex.entryRanges(mbox).count == 2)
    let list = ArchiveIndex.summaries(ofMbox: mbox)
    #expect(list.map(\.subject) == ["둘째", "회의 자료"])   // 최근 메일부터
    let first = try #require(list.first { $0.subject == "회의 자료" })
    #expect(first.hasAttachments && first.preview.hasPrefix("안녕"))
    #expect(MailArchive.matches(first.search, query: "보고서"))
    let back = try ArchiveIndex.decode(ArchiveIndex.encode(list))
    #expect(back == list)
    let url = FileManager.default.temporaryDirectory.appending(path: "archive-index-test.mbox")
    try mbox.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let mail = try ArchiveIndex.message(first, inFile: url)
    #expect(mail.subject == "회의 자료" && mail.attachments.count == 2 && mail.id == first.id)
    let other = try ArchiveIndex.message(try #require(list.first { $0.subject == "둘째" }), inFile: url)
    #expect(other.text == "From here on\n")
}
