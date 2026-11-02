import Foundation

// 화면 글자 번역 (시스템 언어가 한국어면 한국어, 영어면 영어).
// 한국어 원문이 키이고, 영어는 앱 번들의 en.lproj/Localizable.strings에 있다 (Localization/en.lproj).
// 끼워 넣은 값은 종류와 상관없이 키에서 "%@" 하나가 된다: tools/l10n.py가 같은 규칙으로 키를 모은다.
// 원문의 % 글자는 키에서 %%가 된다.

/// L("읽지 않은 메일 \(count)통") → 시스템 언어에 맞는 글자
public func L(_ text: Loc) -> String { text.resolved }

public struct Loc: ExpressibleByStringInterpolation, Sendable {
    public let key: String
    public let args: [String]

    public init(stringLiteral value: String) {
        key = value.replacingOccurrences(of: "%", with: "%%")
        args = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        args = stringInterpolation.args
    }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var key = ""
        var args: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            args.append(String(describing: value))
        }

        public mutating func appendInterpolation<F: FormatStyle>(_ value: F.FormatInput, format: F) where F.FormatOutput == String {
            key += "%@"
            args.append(format.format(value))
        }
    }

    public var resolved: String {
        let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        return String(format: format, arguments: args.map { $0 as NSString })
    }
}

/// 앱이 지금 어느 언어로 보이는지. 날짜 형식도 여기에 맞춘다.
public enum AppLanguage {
    /// en.lproj에는 "@language" = "en"이 있다. 한국어(그리고 단위 테스트)에서는 키가 없어 "ko".
    public static let code: String = Bundle.main.localizedString(forKey: "@language", value: "ko", table: nil)
    public static var isKorean: Bool { code == "ko" }
    /// 날짜·시각 글자의 형식: 한국어면 한국 형식, 아니면 시스템 형식
    public static var locale: Locale { isKorean ? Locale(identifier: "ko_KR") : .autoupdatingCurrent }
}
