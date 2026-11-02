import Foundation

/// 받은 메일 본문을 화면에 안전하게 보이기 위한 규칙.
public enum MailContent {

    /// 화면에 보일 본문: HTML이면 cid 그림을 data: URI로 바꾼다. 평문은 그대로.
    public static func displayBody(_ body: MailMessage.Body?, attachments: [FileAttachment]) -> MailMessage.Body? {
        guard let body else { return nil }
        guard body.isHTML else { return body }
        return MailMessage.Body(contentType: body.contentType, content: resolveInlineImages(html: body.content, attachments: attachments))
    }

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

extension MailContent {
    /// 인쇄용 문서 (S-034): 머리글(제목, 보낸 사람, 받는 사람, 참조, 날짜) + 본문. 본문 안전 규칙(CSP)은 그대로.
    public static func printPage(message m: MailMessage, body: MailMessage.Body?, allowRemote: Bool,
                                 timeZone: TimeZone = .current) -> String {
        func people(_ list: [Recipient]?) -> String {
            HTMLProcessor.escape(AddressParser.format((list ?? []).compactMap { $0.emailAddress.mailAddress }))
        }
        let from = HTMLProcessor.escape(m.from?.emailAddress.mailAddress?.editable ?? m.from?.emailAddress.display ?? "")
        var rows = "<tr><th>보낸 사람</th><td>\(from)</td></tr>"
        rows += "<tr><th>받는 사람</th><td>\(people(m.toRecipients))</td></tr>"
        if !(m.ccRecipients ?? []).isEmpty { rows += "<tr><th>참조</th><td>\(people(m.ccRecipients))</td></tr>" }
        if let date = m.receivedDateTime {
            rows += "<tr><th>날짜</th><td>\(HTMLProcessor.escape(MailDate.long(date, timeZone: timeZone)))</td></tr>"
        }
        let header = """
        <style>@media print{body{padding:0}}.print-head{border-bottom:1px solid #999;margin-bottom:16px;padding-bottom:8px}\
        .print-head h1{font-size:18px;margin:0 0 8px}.print-head th{text-align:left;color:#555;font-weight:normal;\
        padding-right:12px;vertical-align:top;white-space:nowrap}.print-head td,.print-head th{font-size:12px}</style>\
        <div class="print-head"><h1>\(HTMLProcessor.escape(m.title))</h1><table>\(rows)</table></div>
        """
        // 머리글은 본문 문서 안에 넣는다: <body> 태그가 있으면 그 바로 안쪽, 없으면 맨 앞.
        // 평문 메일은 HTML로 바꿔 머리글이 글자로 찍히지 않게 한다. CSP meta는 page()가 맨 앞에 둔다.
        var html: String
        if let body, body.isHTML {
            html = body.content
            if let open = html.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: header, at: open.upperBound)
            } else {
                html = header + html
            }
        } else {
            html = header + "<pre style=\"white-space:pre-wrap;font:inherit\">\(HTMLProcessor.escape(body?.content ?? ""))</pre>"
        }
        return page(body: .init(contentType: "html", content: html), allowRemote: allowRemote)
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
