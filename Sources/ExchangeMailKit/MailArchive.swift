import Foundation

// MARK: 메일상자 내보내기·불러오기 (mbox, eml)
//
// 내보내기: 서버 폴더의 메일 원본(MIME)을 표준 mbox 파일 하나로 (맥 Mail, Thunderbird, Outlook 변환기가 읽는다).
// 불러오기: mbox나 eml 파일을 읽어 메일마다 보낸 사람·제목·날짜·본문·첨부를 꺼낸다.
// 바이트를 ISO-8859-1 글자로 한 번 읽으면 1:1로 되돌릴 수 있어, 머리글과 경계는 글자로 다루고 본문은 바이트로 되돌린다.

/// 보관 파일에서 꺼낸 메일 한 통
public struct ArchivedMail: Identifiable, Sendable {
    public let id: Int
    public var subject: String
    public var from: String
    public var to: String
    public var cc: String
    public var date: Date?
    public var html: String?
    public var text: String?
    public var attachments: [ArchivedAttachment]
    /// 원본 크기 (바이트)
    public var size: Int

    public var title: String { subject.isEmpty ? L("(제목 없음)") : subject }
}

public struct ArchivedAttachment: Identifiable, Sendable {
    public let id: Int
    public var name: String
    public var contentType: String
    public var contentID: String?
    public var isInline: Bool
    public var data: Data
}

public enum MailArchive {

    // MARK: mbox 쓰기

    /// mbox의 메일 하나: "From " 구분 줄 + 원본(본문 안의 "From "으로 시작하는 줄은 ">From "으로) + 빈 줄
    public static func mboxEntry(_ mime: Data, date: Date?) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        var text = latin1(mime).replacingOccurrences(of: "\r\n", with: "\n")
        // mboxrd: 줄 머리의 From (와 >From)에 > 하나를 더 붙인다.
        text = text.replacingOccurrences(of: #"(?m)^(>*From )"#, with: ">$1", options: .regularExpression)
        if !text.hasSuffix("\n") { text += "\n" }
        let separator = "From FAKUKU-Mail \(f.string(from: date ?? Date()))\n"
        return bytes(separator + text + "\n")
    }

    // MARK: mbox·eml 읽기

    /// 파일 내용을 메일 원본 목록으로 나눈다. "From "으로 시작하지 않으면 eml 한 통으로 본다.
    public static func split(_ data: Data) -> [Data] {
        // Swift는 "\r\n"을 한 글자로 보므로 먼저 "\n"으로 바꾼다.
        let text = latin1(data).replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("From ") else { return text.isEmpty ? [] : [data] }
        var messages: [Data] = []
        var current: [Substring] = []
        var previousBlank = true
        func flush() {
            guard !current.isEmpty else { return }
            // 구분 줄 앞의 빈 줄은 mbox가 붙인 것이다.
            while let last = current.last, last.isEmpty { current.removeLast() }
            let body = current.map { line -> String in
                // mboxrd 되돌리기: >From → From
                line.hasPrefix(">") && line.drop { $0 == ">" }.hasPrefix("From ") ? String(line.dropFirst()) : String(line)
            }.joined(separator: "\r\n")
            messages.append(bytes(body + "\r\n"))
            current = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if previousBlank && line.hasPrefix("From ") {
                flush()
            } else {
                current.append(line)
            }
            previousBlank = line.isEmpty
        }
        flush()
        return messages
    }

    /// 보관 파일 전체를 읽는다 (최근 메일부터).
    public static func read(_ data: Data) -> [ArchivedMail] {
        split(data).enumerated()
            .map { parse($0.element, id: $0.offset) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: 목록에 보일 글

    /// "김 대리 <kim@example.com>" → "김 대리" (이름이 없으면 주소)
    public static func displayName(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        guard let lt = trimmed.firstIndex(of: "<") else { return trimmed.isEmpty ? L("(보낸 사람 없음)") : trimmed }
        let name = trimmed[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if !name.isEmpty { return name }
        return trimmed[trimmed.index(after: lt)...].trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// 본문 앞부분 (평문이 없으면 HTML에서 태그를 뺀 글)
    public static func preview(_ mail: ArchivedMail, limit: Int = 160) -> String {
        var source = mail.text ?? ""
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let html = mail.html {
            source = html
                .replacingOccurrences(of: #"(?is)<(style|script|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
        }
        let words = source.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit)) + "…" : words
    }

    // MARK: MIME 해석

    public static func parse(_ data: Data, id: Int = 0) -> ArchivedMail {
        let part = Part(latin1(data))
        var mail = ArchivedMail(id: id, subject: decodeWords(part.header("subject") ?? ""),
                                from: decodeWords(part.header("from") ?? ""),
                                to: decodeWords(part.header("to") ?? ""),
                                cc: decodeWords(part.header("cc") ?? ""),
                                date: part.header("date").flatMap(parseDate),
                                html: nil, text: nil, attachments: [], size: data.count)
        var counter = 0
        walk(part, into: &mail, counter: &counter)
        return mail
    }

    /// MIME 부분 하나: 머리글과 본문(ISO-8859-1 글자)
    struct Part {
        var headers: [(String, String)] = []
        var body: String

        init(_ raw: String) {
            let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            let split = normalized.range(of: "\n\n")
            let head = split.map { String(normalized[..<$0.lowerBound]) } ?? normalized
            body = split.map { String(normalized[$0.upperBound...]) } ?? ""
            // 접힌 머리글 펴기
            var lines: [String] = []
            for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
                if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                    lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                } else {
                    lines.append(String(line))
                }
            }
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                // 인코딩 단어 없이 UTF-8 그대로 쓴 머리글(RFC 6532)도 있다.
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers.append((line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                                String(data: MailArchive.bytes(value), encoding: .utf8) ?? value))
            }
        }

        func header(_ name: String) -> String? { headers.first { $0.0 == name }?.1 }

        var contentType: (type: String, params: [String: String]) {
            MailArchive.headerValue(header("content-type") ?? "text/plain; charset=us-ascii")
        }

        var disposition: (type: String, params: [String: String]) {
            MailArchive.headerValue(header("content-disposition") ?? "")
        }

        /// 전송 인코딩을 푼 본문 바이트
        var decoded: Data {
            switch (header("content-transfer-encoding") ?? "").lowercased() {
            case "base64":
                return Data(base64Encoded: body.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) ?? Data()
            case "quoted-printable":
                return MailArchive.quotedPrintable(body)
            default:
                return MailArchive.bytes(body)
            }
        }
    }

    static func walk(_ part: Part, into mail: inout ArchivedMail, counter: inout Int) {
        let (type, params) = part.contentType
        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for child in children(part.body, boundary: boundary) { walk(Part(child), into: &mail, counter: &counter) }
            return
        }
        let disposition = part.disposition
        let filename = disposition.params["filename"] ?? params["name"]
        let isAttachment = disposition.type == "attachment" || (filename != nil && !type.hasPrefix("text/"))
        if type == "text/html" && !isAttachment && mail.html == nil {
            mail.html = text(part.decoded, charset: params["charset"])
        } else if type == "text/plain" && !isAttachment && mail.text == nil {
            mail.text = text(part.decoded, charset: params["charset"])
        } else if type != "text/plain" && type != "text/html" || isAttachment {
            counter += 1
            let cid = part.header("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            let fallback = type == "message/rfc822" ? L("전달된 메일 \(counter).eml") : (cid.map { L("그림 \($0)") } ?? L("첨부 \(counter)"))
            let name = filename.map(decodeWords) ?? fallback
            mail.attachments.append(ArchivedAttachment(id: counter, name: name, contentType: type, contentID: cid,
                                                       isInline: disposition.type == "inline" || (cid != nil && filename == nil),
                                                       data: part.decoded))
        }
    }

    static func children(_ body: String, boundary: String) -> [String] {
        let marker = "--" + boundary
        var parts: [String] = []
        var current: [Substring]? = nil
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == marker + "--" {
                if let c = current { parts.append(c.joined(separator: "\n")) }
                current = nil
                break
            } else if trimmed == marker {
                if let c = current { parts.append(c.joined(separator: "\n")) }
                current = []
            } else {
                current?.append(line)
            }
        }
        if let c = current { parts.append(c.joined(separator: "\n")) }
        return parts
    }

    // MARK: 머리글 값

    /// "text/html; charset=\"utf-8\"; name*=utf-8''%ED%95%9C" → ("text/html", ["charset": "utf-8", "name": "한"])
    static func headerValue(_ raw: String) -> (type: String, params: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        for c in raw {
            if c == "\"" { quoted.toggle() }
            if c == ";" && !quoted { pieces.append(current); current = "" } else { current.append(c) }
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        var continued: [String: [(Int, String, Bool)]] = [:]
        for p in pieces.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            var key = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            // RFC 2231: name*0*=, name*1*=, name*=charset''…
            let encoded = key.hasSuffix("*")
            if encoded { key.removeLast() }
            if let star = key.lastIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continued[String(key[..<star]), default: []].append((n, value, encoded))
            } else if encoded {
                params[key] = rfc2231(value)
            } else {
                params[key] = value
            }
        }
        for (key, list) in continued {
            let sorted = list.sorted { $0.0 < $1.0 }
            if sorted.first?.2 == true {
                params[key] = rfc2231(sorted.map(\.1).joined())
            } else {
                params[key] = sorted.map(\.1).joined()
            }
        }
        return (type, params)
    }

    /// charset''%XX… → 글자
    static func rfc2231(_ value: String) -> String {
        let parts = value.components(separatedBy: "'")
        guard parts.count >= 3 else { return value.removingPercentEncoding ?? value }
        let charset = parts[0]
        let encoded = parts[2...].joined(separator: "'")
        var data = Data()
        var i = encoded.startIndex
        while i < encoded.endIndex {
            if encoded[i] == "%", let j = encoded.index(i, offsetBy: 3, limitedBy: encoded.endIndex),
               let byte = UInt8(encoded[encoded.index(after: i)..<j], radix: 16) {
                data.append(byte)
                i = j
            } else {
                data.append(contentsOf: Array(String(encoded[i]).utf8))
                i = encoded.index(after: i)
            }
        }
        return text(data, charset: charset)
    }

    /// RFC 2047: =?utf-8?B?…?= =?euc-kr?Q?…?= 를 푼다. 붙어 있는 인코딩 단어 사이 공백은 지운다.
    public static func decodeWords(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return raw }
        let collapsed = raw.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        let ns = collapsed as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: collapsed, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1))
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            let data = mode == "B"
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
                : quotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
            out += text(data, charset: charset)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func quotedPrintable(_ s: String) -> Data {
        // 본문은 ISO-8859-1 글자라 bytes()로 원래 바이트가 그대로 나온다.
        let src = [UInt8](bytes(s.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")))
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: b - 48
            case 65...70: b - 55
            case 97...102: b - 87
            default: nil
            }
        }
        var data = Data()
        var i = 0
        while i < src.count {
            if src[i] == UInt8(ascii: "="), i + 2 < src.count, let high = hex(src[i + 1]), let low = hex(src[i + 2]) {
                data.append(high << 4 | low)
                i += 3
            } else {
                data.append(src[i])
                i += 1
            }
        }
        return data
    }

    /// 본문 HTML의 cid: 그림을 data: 주소로 바꾼다 (보관 파일엔 서버가 없으므로)
    public static func inlineImages(_ mail: ArchivedMail) -> String? {
        guard var html = mail.html else { return nil }
        for a in mail.attachments {
            guard let cid = a.contentID, !cid.isEmpty else { continue }
            html = html.replacingOccurrences(of: "cid:\(cid)", with: "data:\(a.contentType);base64,\(a.data.base64EncodedString())")
        }
        return html
    }

    /// 바이트를 글자로: 지정 charset, 안 되면 UTF-8, EUC-KR, ISO-8859-1 순으로
    public static func text(_ data: Data, charset: String?) -> String {
        var candidates: [String.Encoding] = []
        if let charset, !charset.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) as CFString)
            if cf != kCFStringEncodingInvalidId {
                candidates.append(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
            }
        }
        candidates.append(.utf8)
        candidates.append(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))))
        for e in candidates { if let s = String(data: data, encoding: e) { return s } }
        return latin1(data)
    }

    static func parseDate(_ raw: String) -> Date? {
        let cleaned = raw.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"] {
            f.dateFormat = format
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    // MARK: 바이트 ↔ 글자 (1:1)

    static func latin1(_ data: Data) -> String { String(data: data, encoding: .isoLatin1) ?? "" }
    static func bytes(_ s: String) -> Data { s.data(using: .isoLatin1) ?? Data(s.utf8) }
}
