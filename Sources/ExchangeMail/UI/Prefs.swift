import AppKit
import SwiftUI

/// 설정 값의 키와 기본값 (설정 > 작성·보기·서체 및 색상). 뷰는 같은 키로 @AppStorage를 쓰고,
/// 모델은 여기서 읽는다. 테스트·스냅숏(Store.isOverridden)은 저장된 값을 보지 않고 기본값을 쓴다.
enum Prefs {
    // 작성
    static let spellcheck = "compose.spellcheck"            // Bool, true
    static let autoIncludeMe = "compose.autoIncludeMe"      // String: none, cc, bcc
    static let highlightExternal = "compose.highlightExternal" // Bool, false
    static let internalDomains = "compose.internalDomains"  // String "@corp.com, @corp.co.kr"
    static let quoteOriginal = "compose.quoteOriginal"      // Bool, true
    // 작성 창 머리글 필드 (보기 메뉴, 작성 창의 머리글 필드 단추)
    static let fieldCc = "compose.field.cc"                 // Bool, true
    static let fieldBcc = "compose.field.bcc"               // Bool, false
    static let fieldReplyTo = "compose.field.replyTo"       // Bool, false
    static let fieldPriority = "compose.field.priority"     // Bool, true
    // 보기
    static let previewLines = "view.previewLines"           // Int, 2 (0~5)
    static let boldUnread = "view.boldUnread"               // Bool, true
    static let selectNextAfterMove = "view.selectNextAfterMove" // Bool, true
    static let threadAllFolders = "view.threadAllFolders"   // Bool, true
    static let threadNewestFirst = "view.threadNewestFirst" // Bool, false
    static let markRead = "view.markRead"                   // String: now, delay, never
    static let threadHeight = "view.threadHeight"           // Double, 176 (본문 위 대화 목록 높이)
    // 서체 및 색상
    static let listFontSize = "font.listSize"               // Int, 13
    static let bodyFontFamily = "font.bodyFamily"           // String, "" (시스템)
    static let bodyFontSize = "font.bodySize"               // Int, 14
    static let plainMonospace = "font.plainMonospace"       // Bool, false
    static let quoteColors = "font.quoteColors"             // Bool, true
    static let quoteColor1 = "font.quote1"
    static let quoteColor2 = "font.quote2"
    static let quoteColor3 = "font.quote3"

    /// 인용 단계 색 기본값 (맥 Mail과 같은 보라, 청록, 초록)
    static let defaultQuoteColors = ["#5856D6", "#00A3BF", "#34C759"]

    /// 본문 위 대화 목록의 높이 (경계선을 끌어 바꾼다)
    static let threadHeightDefault = 176.0
    static let threadHeightStep = 48.0
    static func clampThreadHeight(_ value: Double) -> Double { min(max(value, 64), 640) }

    /// 보기 메뉴: 대화 목록 높이를 늘리거나 줄인다 (0이면 기본 높이로)
    static func adjustThreadHeight(by delta: Double) {
        let current = UserDefaults.standard.object(forKey: threadHeight) as? Double ?? threadHeightDefault
        UserDefaults.standard.set(delta == 0 ? threadHeightDefault : clampThreadHeight(current + delta), forKey: threadHeight)
    }

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard !Store.isOverridden, UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func string(_ key: String, _ fallback: String) -> String {
        guard !Store.isOverridden else { return fallback }
        return UserDefaults.standard.string(forKey: key) ?? fallback
    }
}

/// 본문 웹 보기에 덧붙이는 읽기 스타일 (설정 > 서체 및 색상). 메일 HTML 뒤에 붙여 기본값만 바꾼다.
struct ReadingStyle: Equatable {
    var family = ""
    var size = 14
    var plainMonospace = false
    var quoteColors = true
    var quote = Prefs.defaultQuoteColors

    var css: String {
        var rules: [String] = []
        let fam = family.isEmpty ? "-apple-system,'Apple SD Gothic Neo',sans-serif"
                                 : "'\(family.replacingOccurrences(of: "'", with: ""))',-apple-system,sans-serif"
        rules.append("body{font-family:\(fam);font-size:\(size)px}")
        if plainMonospace { rules.append("pre{font-family:ui-monospace,Menlo,monospace !important}") }
        if quoteColors {
            let q = "blockquote[type=cite]"
            let safe = quote.map { $0.filter { $0.isHexDigit || $0 == "#" } }
            rules.append("\(q){border-left:2px solid \(safe[0]);color:\(safe[0])}")
            rules.append("\(q) \(q){border-left-color:\(safe[1]);color:\(safe[1])}")
            rules.append("\(q) \(q) \(q){border-left-color:\(safe[2]);color:\(safe[2])}")
        }
        return "<style>\(rules.joined())</style>"
    }
}

extension Color {
    /// "#RRGGBB" → 색. 틀리면 nil.
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// 색 → "#RRGGBB" (sRGB)
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
