import Foundation

// M24 2단계: iCloud·Gmail 보내기(SMTP)에 쓰는 순수 코드. 연결은 앱의 Mail/SMTPClient.swift.
// 앱이 만든 MIME(Graph에도 그대로 보내는 것)에서 보내는 사람·받는 사람을 읽고, 숨은 참조 머리글을 빼고,
// 점 줄을 막아(dot-stuffing) DATA로 보낸다.

public enum SMTP {

    /// 서버 응답 한 묶음: "250-…" 줄들 뒤 "250 …"
    public struct Reply: Equatable, Sendable {
        public var code: Int
        public var lines: [String]
        public var text: String { lines.joined(separator: " ") }
        public var isPositive: Bool { (200..<400).contains(code) }
    }

    /// 줄들에서 완성된 응답 하나. 마지막 줄은 "ddd "로 시작한다. 아직이면 nil.
    public static func reply(from lines: [String]) -> Reply? {
        guard let last = lines.last, last.count >= 3, let code = Int(last.prefix(3)) else { return nil }
        let isFinal = last.count == 3 || last[last.index(last.startIndex, offsetBy: 3)] == " "
        guard isFinal else { return nil }
        return Reply(code: code, lines: lines.map { $0.count > 4 ? String($0.dropFirst(4)) : "" })
    }

    /// AUTH PLAIN 값: base64("\0사용자\0암호")
    public static func plainAuth(user: String, password: String) -> String {
        Data(("\u{0}" + user + "\u{0}" + password).utf8).base64EncodedString()
    }

    /// MIME 머리글에서 보내는 사람(From)과 받는 사람(To, Cc, Bcc)의 주소
    public static func envelope(_ mime: Data) -> (from: String?, recipients: [String]) {
        let part = MailArchive.Part(MailArchive.latin1(headerBlock(mime)))
        func addresses(_ name: String) -> [String] {
            part.headers.filter { $0.0 == name }
                .flatMap { AddressParser.parse(MailArchive.decodeWords($0.1)).valid.map(\.address) }
        }
        var seen = Set<String>()
        let recipients = (addresses("to") + addresses("cc") + addresses("bcc")).filter { seen.insert($0.lowercased()).inserted }
        return (addresses("from").first, recipients)
    }

    /// 머리글의 Message-ID
    public static func messageID(_ mime: Data) -> String? {
        MailArchive.Part(MailArchive.latin1(headerBlock(mime))).header("message-id")
    }

    /// 머리글 부분 (첫 빈 줄까지)
    static func headerBlock(_ mime: Data) -> Data {
        let head = mime.prefix(256 * 1024)
        if let r = head.range(of: Data("\r\n\r\n".utf8)) { return head[head.startIndex..<r.upperBound] }
        if let r = head.range(of: Data("\n\n".utf8)) { return head[head.startIndex..<r.upperBound] }
        return head
    }

    /// 받는 사람에게는 숨은 참조(Bcc) 머리글을 지워 보낸다 (접힌 다음 줄까지)
    /// 바이트로 줄을 나눈다: Swift 글자로 나누면 "\r\n"이 글자 하나라 CRLF 메일의 줄이 나뉘지 않아 Bcc가 남았다.
    public static func removingBcc(_ mime: Data) -> Data {
        let head = headerBlock(mime)
        var result = Data()
        var skipping = false
        var start = head.startIndex
        while start < head.endIndex {
            let end = head[start...].firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? head.endIndex
            let line = head[start..<end]
            defer { start = end }
            if skipping, let first = line.first, first == UInt8(ascii: " ") || first == UInt8(ascii: "\t") { continue }
            skipping = String(decoding: line.prefix(4), as: UTF8.self).lowercased() == "bcc:"
            if !skipping { result.append(line) }
        }
        result.append(mime[(mime.startIndex + head.count)...])
        return result
    }

    /// DATA로 보낼 바이트: 줄 끝을 CRLF로, "."로 시작하는 줄은 "."을 하나 더, 끝에 "\r\n.\r\n"
    public static func dataPayload(_ mime: Data) -> Data {
        var out = Data()
        out.reserveCapacity(mime.count + mime.count / 64 + 8)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in mime {
            if byte == 10 && previous != 13 { out.append(13) }
            if atLineStart && byte == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(byte)
            atLineStart = byte == 10
            previous = byte
        }
        if !atLineStart { out.append(contentsOf: [13, 10]) }
        out.append(contentsOf: Array(".\r\n".utf8))
        return out
    }
}
