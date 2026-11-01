import Foundation

/// 메일 주소 하나: `홍길동 <hong@example.com>`.
public struct MailAddress: Hashable, Codable, Sendable {
    public var name: String?
    public var address: String

    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }

    /// 화면에 보일 이름: 이름이 있으면 이름, 없으면 주소.
    public var display: String {
        if let name, !name.isEmpty { name } else { address }
    }

    /// 입력 칸에 다시 넣을 때 쓰는 형태.
    public var editable: String {
        if let name, !name.isEmpty { "\(name) <\(address)>" } else { address }
    }
}

public enum AddressParser {

    /// 받는 사람 칸 글자를 주소 목록으로 읽는다. 쉼표·세미콜론·줄바꿈으로 나누고,
    /// 따옴표나 꺾쇠 안의 쉼표는 나누지 않는다. 형식이 틀린 항목은 `invalid`에 원문 그대로 담는다.
    public static func parse(_ text: String) -> (valid: [MailAddress], invalid: [String]) {
        var valid: [MailAddress] = []
        var invalid: [String] = []
        for token in split(text) {
            if let address = parseOne(token) {
                if !valid.contains(where: { $0.address.lowercased() == address.address.lowercased() }) {
                    valid.append(address)
                }
            } else {
                invalid.append(token)
            }
        }
        return (valid, invalid)
    }

    static func split(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in text {
            // `case a, b where ...`의 where는 마지막 패턴에만 붙으므로 if로 쓴다.
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "<" && !inQuotes {
                inAngle = true
                current.append(ch)
            } else if ch == ">" && !inQuotes {
                inAngle = false
                current.append(ch)
            } else if (ch == "," || ch == ";" || ch.isNewline) && !inQuotes && !inAngle {
                tokens.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        tokens.append(current)
        return tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func parseOne(_ token: String) -> MailAddress? {
        if let open = token.lastIndex(of: "<"), let close = token.lastIndex(of: ">"), open < close {
            let address = token[token.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = token[..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            guard isValid(address) else { return nil }
            return MailAddress(name: name.isEmpty ? nil : name, address: address)
        }
        return isValid(token) ? MailAddress(address: token) : nil
    }

    public static func isValid(_ address: String) -> Bool {
        address.range(of: #"^[^\s@<>()",;]+@[^\s@<>()",;]+\.[^\s@<>()",;.]+$"#, options: .regularExpression) != nil
    }

    /// 주소 목록을 입력 칸 글자로.
    public static func format(_ addresses: [MailAddress]) -> String {
        addresses.map(\.editable).joined(separator: ", ")
    }
}
