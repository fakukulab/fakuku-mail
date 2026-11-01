import Foundation

/// 첨부 파일명 보정 (기획안 F3, F5, F6).
/// - NFC 정규화: macOS가 주는 자모 분리(NFD) 이름을 완성형으로.
/// - RFC 2047 Base64 encoded-word + RFC 2231 `filename*`을 함께 기록: Outlook·Windows·웹메일 모두 한글로 읽는다.
/// - EUC-KR 옵션: 구형 국내 시스템용. 표현할 수 없는 글자가 있으면 UTF-8로 되돌아간다.
public enum FilenameEncoder {

    /// NFC 정규화, 경로 구분자와 제어 문자 제거.
    public static func normalize(_ name: String) -> String {
        var n = name.precomposedStringWithCanonicalMapping
        n = n.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        n = String(n.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        n = n.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "attachment" : n
    }

    /// RFC 2047 B encoded-word 목록. 글자(자소 클러스터) 경계에서만 자르므로 단어 하나만 디코딩해도 깨지지 않는다.
    /// `maxRawBytes` 42 → base64 56자 + `=?UTF-8?B?` `?=` 12자 = 68자로, 한 단어가 75자 제한 안에 든다.
    public static func rfc2047Words(_ text: String, charset: String = "UTF-8",
                                    encoding: String.Encoding = .utf8,
                                    maxRawBytes: Int = 42) -> [String] {
        var words: [String] = []
        var chunk = Data()
        func flush() {
            guard !chunk.isEmpty else { return }
            words.append("=?\(charset)?B?\(chunk.base64EncodedString())?=")
            chunk.removeAll()
        }
        for ch in text {
            guard let d = String(ch).data(using: encoding) else { continue }
            if chunk.count + d.count > maxRawBytes { flush() }
            chunk.append(d)
        }
        flush()
        return words
    }

    /// RFC 2231 / RFC 5987 attr-char. ASCII만: `CharacterSet.alphanumerics`는 한글도 포함하므로 쓰면 안 된다.
    static let attrChars = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")

    static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: attrChars) ?? text
    }

    /// `UTF-8''%EA%B2%AC...` 값 (한 줄에 다 쓸 때).
    public static func rfc2231Value(_ name: String) -> String {
        "UTF-8''\(percentEncode(name))"
    }

    /// RFC 2231 파라미터. 길면 `key*0*=`, `key*1*=` 연속 파라미터로 나눠 한 줄이 짧게 유지된다.
    /// 나누는 자리는 글자 경계라서, 조각마다 따로 디코딩하는 프로그램에서도 깨지지 않는다.
    public static func rfc2231Parameter(key: String, filename name: String, maxSegment: Int = 60) -> String {
        let whole = percentEncode(name)
        if whole.count <= maxSegment { return "\(key)*=UTF-8''\(whole)" }
        var segments: [String] = []
        var current = ""
        for ch in name {
            let piece = percentEncode(String(ch))
            if !current.isEmpty && current.count + piece.count > maxSegment {
                segments.append(current)
                current = ""
            }
            current += piece
        }
        if !current.isEmpty { segments.append(current) }
        return segments.enumerated().map { index, segment in
            index == 0 ? "\(key)*0*=UTF-8''\(segment)" : "\(key)*\(index)*=\(segment)"
        }.joined(separator: ";\r\n ")
    }

    static func isASCIISafe(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" }
    }

    /// `Content-Type`(`name`) 또는 `Content-Disposition`(`filename`) 뒤에 붙일 파라미터.
    /// 예: `filename="=?UTF-8?B?...?="; filename*=UTF-8''...` (CRLF + 공백으로 접힘)
    public static func parameter(key: String, filename raw: String, eucKR: Bool = false) -> String {
        let name = normalize(raw)
        if isASCIISafe(name) { return "\(key)=\"\(name)\"" }

        if eucKR, let euc = eucKREncoding, name.canBeConverted(to: euc) {
            let words = rfc2047Words(name, charset: "EUC-KR", encoding: euc)
            return "\(key)=\"\(words.joined(separator: "\r\n "))\""
        }
        let words = rfc2047Words(name)
        return "\(key)=\"\(words.joined(separator: "\r\n "))\";\r\n " + rfc2231Parameter(key: key, filename: name)
    }

    /// KS X 1001 EUC-KR. CP949 확장 글자(예: 똠, 햏)는 표현하지 못하므로 그때는 UTF-8을 쓴다.
    public static var eucKREncoding: String.Encoding? {
        let cf = CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
        let ns = CFStringConvertEncodingToNSStringEncoding(cf)
        return ns == UInt(kCFStringEncodingInvalidId) ? nil : String.Encoding(rawValue: ns)
    }
}
