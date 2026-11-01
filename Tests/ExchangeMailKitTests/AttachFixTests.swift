import Foundation
import Testing
@testable import ExchangeMailKit

// S-005, S-006, S-008: 첨부 보정

@Test("NFD 한글 파일명을 NFC로 정규화한다")
func nfcNormalization() {
    let nfd = "견적서.pdf".decomposedStringWithCanonicalMapping
    #expect(nfd.unicodeScalars.count != "견적서.pdf".unicodeScalars.count)
    #expect(FilenameEncoder.normalize(nfd) == "견적서.pdf")
}

@Test("경로 구분자와 제어 문자를 뺀다", arguments: [
    ("a/b.txt", "a_b.txt"),
    ("a\\b.txt", "a_b.txt"),
    ("tab\there.txt", "tabhere.txt"),
    ("   ", "attachment"),
])
func sanitize(_ input: String, expected: String) {
    #expect(FilenameEncoder.normalize(input) == expected)
}

@Test("encoded-word는 75자 이내이고 이어 붙이면 원래 이름이다")
func encodedWordsRoundTrip() throws {
    let name = String(repeating: "현장사진_최종본", count: 12) + ".jpg"
    let words = FilenameEncoder.rfc2047Words(name)
    #expect(words.allSatisfy { $0.count <= 75 })
    var decoded = ""
    for w in words {
        let b64 = w.dropFirst("=?UTF-8?B?".count).dropLast(2)
        let data = try #require(Data(base64Encoded: String(b64)))
        decoded += try #require(String(data: data, encoding: .utf8))
    }
    #expect(decoded == name)
}

@Test("한글 파일명에 RFC 2047과 RFC 2231을 함께 쓰고, 한글을 퍼센트 인코딩한다")
func bothForms() {
    let p = FilenameEncoder.parameter(key: "filename", filename: "견적서.pdf")
    #expect(p.contains("filename=\"=?UTF-8?B?"))
    #expect(p.contains("filename*=UTF-8''%EA%B2%AC%EC%A0%81%EC%84%9C.pdf"))
    #expect(!p.contains("견"))
}

@Test("긴 이름은 RFC 2231 연속 파라미터로 나누고, 나눈 조각을 이으면 원래 값이다")
func continuation() {
    let name = String(repeating: "가", count: 30) + ".pdf"
    let p = FilenameEncoder.rfc2231Parameter(key: "filename", filename: name)
    #expect(p.hasPrefix("filename*0*=UTF-8''"))
    #expect(p.contains("filename*1*="))
    let joined = p.components(separatedBy: ";\r\n ").map { part in
        String(part[part.index(after: part.firstIndex(of: "=")!)...]).replacingOccurrences(of: "UTF-8''", with: "")
    }.joined()
    #expect(joined.removingPercentEncoding == name)
    // 조각마다 따로 디코딩해도 깨지지 않는다 (글자 경계에서 나눔)
    for part in p.components(separatedBy: ";\r\n ") {
        let value = String(part[part.index(after: part.firstIndex(of: "=")!)...]).replacingOccurrences(of: "UTF-8''", with: "")
        #expect(value.removingPercentEncoding != nil)
    }
}

@Test("ASCII 이름은 그대로 둔다")
func asciiPlain() {
    #expect(FilenameEncoder.parameter(key: "name", filename: "a.pdf") == "name=\"a.pdf\"")
}

@Test("EUC-KR로 쓸 수 있으면 EUC-KR, 아니면 UTF-8로 되돌아간다")
func eucKRFallback() {
    let ok = FilenameEncoder.parameter(key: "filename", filename: "견적서.pdf", eucKR: true)
    #expect(ok.contains("=?EUC-KR?B?"))
    #expect(!ok.contains("filename*="))
    // '똠'은 KS X 1001 EUC-KR에 없다. 시스템 변환기가 CP949 확장까지 받아 주면 이 확인은 건너뛴다.
    if let euc = FilenameEncoder.eucKREncoding, !"똠".canBeConverted(to: euc) {
        let fallback = FilenameEncoder.parameter(key: "filename", filename: "똠방각하.pdf", eucKR: true)
        #expect(fallback.contains("=?UTF-8?B?"))
        #expect(fallback.contains("filename*="))
    }
    // 이모지는 어떤 경우에도 EUC-KR로 쓸 수 없다
    let emoji = FilenameEncoder.parameter(key: "filename", filename: "보고서🚀.pdf", eucKR: true)
    #expect(emoji.contains("=?UTF-8?B?"))
}

let tinyPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString()

@Test("본문 이미지는 첨부로, 서명과 인용문 이미지는 인라인으로")
func bodyImageBecomesAttachment() {
    let html = """
    <p>본문<img src="data:image/png;base64,\(tinyPNG)" alt="현장사진.png"></p>
    <div data-signature="x"><div><img src="data:image/png;base64,\(tinyPNG)" alt="logo.png"></div></div>
    <div data-quote="reply"><img src='data:image/png;base64,\(tinyPNG)'></div>
    """
    let r = HTMLProcessor.process(html: html, convertBodyImagesToAttachments: true)
    #expect(r.images.count == 3)
    #expect(r.images[0].contentID == nil)
    #expect(r.images[0].filename == "현장사진.png")
    #expect(r.images[1].contentID != nil)
    #expect(r.images[2].contentID != nil)
    #expect(!r.html.contains("현장사진"))
    #expect(r.html.components(separatedBy: "<img").count - 1 == 2)
    #expect(r.html.components(separatedBy: "cid:").count - 1 == 2)
    #expect(HTMLProcessor.bodyImageCount(in: html) == 1)
}

@Test("앞에 NFD 글자나 이모지가 있어도 서명 위치를 바르게 찾는다")
func offsetsWithCombiningCharacters() {
    let prefix = "가나다".decomposedStringWithCanonicalMapping + "👨‍👩‍👧"
    let html = prefix + "<div data-signature=\"s\"><img src=\"data:image/png;base64,\(tinyPNG)\"></div>"
    let r = HTMLProcessor.process(html: html, convertBodyImagesToAttachments: true)
    #expect(r.images.count == 1)
    #expect(r.images[0].contentID != nil)
}

@Test("보정을 끄면 본문 이미지도 인라인으로 남는다")
func fixOff() {
    let html = "<p><img src=\"data:image/png;base64,\(tinyPNG)\"></p>"
    let r = HTMLProcessor.process(html: html, convertBodyImagesToAttachments: false)
    #expect(r.images.first?.contentID != nil)
}

@Test("최소 크기보다 작은 본문 이미지는 인라인으로 남는다")
func minSize() {
    let html = "<p><img src=\"data:image/png;base64,\(tinyPNG)\"></p>"
    let r = HTMLProcessor.process(html: html, convertBodyImagesToAttachments: true, minInlineBytes: 1024)
    #expect(r.images.first?.contentID != nil)
}

func mime(_ msg: OutgoingMessage, _ options: FixOptions = FixOptions()) -> String {
    String(decoding: MIMEBuilder.build(msg, options: options, messageID: "id1@test"), as: UTF8.self)
}

@Test("첨부가 있는 메일은 multipart/mixed, 제목은 encoded-word")
func mimeStructure() {
    let msg = OutgoingMessage(from: MailAddress(name: "홍길동", address: "a@b.com"),
                              to: [MailAddress(address: "c@d.com")], subject: "견적서 송부",
                              html: "<p>hi<img src=\"data:image/png;base64,\(tinyPNG)\"></p>",
                              attachments: [OutgoingAttachment(filename: "견적서.pdf", mimeType: "application/pdf", data: Data([9]))])
    let s = mime(msg)
    #expect(s.contains("multipart/mixed"))
    #expect(s.contains("Content-Disposition: attachment"))
    #expect(s.contains("Subject: =?UTF-8?B?"))
    #expect(s.contains("From: =?UTF-8?B?"))
    #expect(s.contains("Message-ID: <id1@test>"))
    #expect(!s.contains("multipart/related"))
    #expect(s.components(separatedBy: "Content-Disposition: attachment").count - 1 == 2)
}

@Test("헤더 줄은 998자를 넘지 않고 모든 줄이 CRLF로 끝난다")
func lineLimits() {
    let longName = String(repeating: "아주긴파일이름", count: 20) + ".xlsx"
    let msg = OutgoingMessage(from: MailAddress(address: "a@b.com"), to: [MailAddress(address: "c@d.com")],
                              subject: String(repeating: "긴 제목 ", count: 30), html: "<p>x</p>",
                              attachments: [OutgoingAttachment(filename: longName, mimeType: "application/octet-stream", data: Data([1]))])
    let s = mime(msg)
    let lines = s.components(separatedBy: "\r\n")
    #expect(lines.allSatisfy { $0.utf8.count <= 998 })
    #expect(!s.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
}

@Test("답장 헤더: In-Reply-To와 References")
func replyHeaders() {
    let msg = OutgoingMessage(from: MailAddress(address: "a@b.com"), to: [MailAddress(address: "c@d.com")],
                              subject: "RE: x", html: "<p>x</p>",
                              inReplyTo: "<orig@x>", references: ["<root@x>", "<orig@x>"])
    let s = mime(msg)
    #expect(s.contains("In-Reply-To: <orig@x>\r\n"))
    #expect(s.contains("References: <root@x>\r\n <orig@x>\r\n"))
}

@Test("Graph 요청 크기 계산은 base64 크기다")
func requestSize() {
    #expect(MIMEBuilder.graphRequestSize(forMIMEBytes: 3) == 4)
    #expect(MIMEBuilder.graphRequestSize(forMIMEBytes: 4) == 8)
}

// S-017 끌어다 놓기

@Test("첨부 목록은 같은 파일을 한 번만 넣고 폴더는 건너뛴다")
func mergeAttachments() {
    let a = URL(fileURLWithPath: "/tmp/a.pdf")
    let nfd = URL(fileURLWithPath: "/tmp/" + "견적서.pdf".decomposedStringWithCanonicalMapping)
    let nfc = URL(fileURLWithPath: "/tmp/견적서.pdf")
    let folder = URL(fileURLWithPath: "/tmp/사진", isDirectory: true)
    let r = AttachmentList.merge([a], adding: [a, nfd, nfc, folder], isDirectory: { $0 == folder })
    #expect(r.files == [a, nfd])
    #expect(r.skipped == ["사진"])
}

// S-023 4MB가 넘는 메일

@Test("요청이 4MB를 넘으면 가장 큰 첨부부터 업로드로 옮긴다")
func graphPlanMovesLargest() {
    let big = OutgoingAttachment(filename: "큰파일.pdf", mimeType: "application/pdf", data: Data(count: 5_000_000))
    let mid = OutgoingAttachment(filename: "중간.zip", mimeType: "application/zip", data: Data(count: 2_500_000))
    let small = OutgoingAttachment(filename: "작은.txt", mimeType: "text/plain", data: Data(count: 10_000))
    let msg = OutgoingMessage(from: MailAddress(address: "a@b.com"), to: [MailAddress(address: "c@d.com")],
                              subject: "큰 메일", html: "<p>본문</p>", attachments: [mid, big, small])
    let plan = MIMEBuilder.buildForGraph(msg, messageID: "x@test")
    #expect(plan.uploads.map(\.filename) == ["큰파일.pdf", "중간.zip"])
    #expect(!plan.mimeTooLarge)
    #expect(MIMEBuilder.graphRequestSize(forMIMEBytes: plan.mime.count) <= MIMEBuilder.graphRequestLimit)
    let text = String(decoding: plan.mime, as: UTF8.self)
    #expect(text.contains("filename*=UTF-8''%EC%9E%91%EC%9D%80.txt"))
    #expect(!text.contains("%ED%81%B0%ED%8C%8C%EC%9D%BC"))
}

@Test("작은 메일은 업로드 없이 MIME 하나로 보낸다")
func graphPlanSmall() {
    let msg = OutgoingMessage(from: MailAddress(address: "a@b.com"), to: [MailAddress(address: "c@d.com")],
                              subject: "작은 메일", html: "<p>본문</p>",
                              attachments: [OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data(count: 100))])
    let plan = MIMEBuilder.buildForGraph(msg)
    #expect(plan.uploads.isEmpty)
    #expect(!plan.mimeTooLarge)
}

@Test("본문 안 그림만으로 한도를 넘으면 알 수 있다")
func graphPlanInlineTooLarge() {
    let huge = Data(count: 3_500_000).base64EncodedString()
    let msg = OutgoingMessage(from: MailAddress(address: "a@b.com"), to: [MailAddress(address: "c@d.com")],
                              subject: "x", html: "<div data-signature=\"s\"><img src=\"data:image/png;base64,\(huge)\"></div>")
    #expect(MIMEBuilder.buildForGraph(msg).mimeTooLarge)
}

@Test("업로드 조각은 320 KiB의 배수이고 끝까지 이어진다")
func uploadChunks() {
    let total = 10_000_000
    let ranges = UploadChunks.ranges(total: total)
    #expect(UploadChunks.defaultChunk % UploadChunks.unit == 0)
    #expect(ranges.first?.lowerBound == 0)
    #expect(ranges.last?.upperBound == total)
    #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    #expect(ranges.dropLast().allSatisfy { $0.count == UploadChunks.defaultChunk })
    #expect(UploadChunks.contentRange(ranges[0], total: total) == "bytes 0-3276799/10000000")
    #expect(UploadChunks.ranges(total: 0).isEmpty)
}
