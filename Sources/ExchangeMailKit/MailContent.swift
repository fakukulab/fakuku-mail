import Foundation

/// 받은 메일 본문을 화면에 안전하게 보이기 위한 규칙.
public enum MailContent {

    /// `cid:` 그림을 인라인 첨부의 data: URI로 바꾼다. 찾지 못한 cid는 그대로 둔다.
    public static func resolveInlineImages(html: String, attachments: [FileAttachment]) -> String {
        var map: [String: String] = [:]
        for a in attachments {
            guard let cid = a.contentId, let bytes = a.contentBytes else { continue }
            let key = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
            map[key] = "data:\(a.contentType ?? "application/octet-stream");base64,\(bytes)"
        }
        guard !map.isEmpty,
              let re = try? NSRegularExpression(pattern: #"(src\s*=\s*)(["'])cid:([^"']+)\2"#, options: [.caseInsensitive])
        else { return html }
        let result = NSMutableString(string: html)
        let matches = re.matches(in: html, range: NSRange(location: 0, length: result.length))
        for m in matches.reversed() {
            let ns = html as NSString
            let cid = ns.substring(with: m.range(at: 3)).removingPercentEncoding ?? ns.substring(with: m.range(at: 3))
            guard let uri = map[cid.lowercased()] else { continue }
            let quote = ns.substring(with: m.range(at: 2))
            result.replaceCharacters(in: m.range, with: "\(ns.substring(with: m.range(at: 1)))\(quote)\(uri)\(quote)")
        }
        return result as String
    }

    /// 원격(http, https)에서 불러오는 그림·배경이 있는지.
    public static func hasRemoteContent(_ html: String) -> Bool {
        let patterns = [#"<img\b[^>]*\bsrc\s*=\s*["']?\s*(https?:)?//"#,
                        #"\bbackground\s*=\s*["']?\s*(https?:)?//"#,
                        #"url\(\s*["']?\s*(https?:)?//"#]
        return patterns.contains { html.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// 콘텐츠 보안 정책. 스크립트는 WKWebView 설정으로도 꺼 두지만 여기서도 막는다.
    public static func contentSecurityPolicy(allowRemote: Bool) -> String {
        allowRemote
            ? "default-src 'none'; img-src * data:; style-src * 'unsafe-inline'; font-src * data:; media-src * data:"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
    }

    /// 웹 보기용 문서. CSP meta는 맨 앞에 두어 메일 HTML보다 먼저 적용되게 한다.
    public static func page(body: MailMessage.Body?, allowRemote: Bool) -> String {
        let content: String
        if let body, body.isHTML {
            content = body.content
        } else {
            content = "<pre style=\"white-space:pre-wrap;font:inherit\">\(HTMLProcessor.escape(body?.content ?? ""))</pre>"
        }
        return """
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowRemote: allowRemote))">\
        <meta name="color-scheme" content="light dark">\
        <style>html,body{margin:0}body{font:14px -apple-system,'Apple SD Gothic Neo',sans-serif;padding:16px 20px;\
        word-wrap:break-word}img{max-width:100%;height:auto}blockquote[type=cite]{margin-left:0;padding-left:10px;\
        border-left:2px solid #b4b4b4}</style>
        """ + content
    }
}

/// 목록과 인용문에 쓰는 날짜 글자. 앱 UI가 한국어라 한국어 형식으로 고정한다.
public enum MailDate {
    static let korean = Locale(identifier: "ko_KR")

    /// 오늘: "오후 3:12", 어제: "어제", 이번 주: "화요일", 그 전: "2025. 3. 4."
    public static func listLabel(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = korean
        if cal.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: korean,
                                                   calendar: cal, timeZone: timeZone))
        }
        let startOfToday = cal.startOfDay(for: now)
        if let yesterday = cal.date(byAdding: .day, value: -1, to: startOfToday), date >= yesterday, date < startOfToday {
            return "어제"
        }
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < startOfToday {
            return date.formatted(Date.FormatStyle(locale: korean, calendar: cal, timeZone: timeZone).weekday(.wide))
        }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: korean,
                                               calendar: cal, timeZone: timeZone))
    }

    /// "2025년 3월 4일 오후 3:12"
    public static func long(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: korean,
                                               calendar: cal, timeZone: timeZone))
    }
}
