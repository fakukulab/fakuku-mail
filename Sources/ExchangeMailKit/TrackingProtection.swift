import Foundation

/// 받은 메일의 원격 콘텐츠를 어떻게 다룰지 (S-047)
public enum RemoteContent: String, Codable, Sendable {
    /// 막는다 (불러오기를 눌러야 보인다)
    case blocked
    /// 메일 활동 보호: 추적기는 빼고, 나머지 그림은 앱이 쿠키·리퍼러 없이 대신 받아 보여 준다
    case proxied
    /// 원래 서버에서 그대로 불러온다
    case allowed
}

/// 메일 활동 보호 (S-047). 맥 Mail처럼 IP 주소를 숨기려면 중계 서버가 필요해 하지 않는다:
/// 그림을 받는 요청은 이 Mac에서 나가지만, 메일을 연 순간과 열지 않은 메일은 알 수 없게 한다.
public enum TrackingProtection {
    /// 앱이 대신 받는 그림의 URL scheme. 웹 보기에서 `ProxyImageLoader`가 처리한다.
    public static let scheme = "fakuku-proxy"

    /// 알려진 열람 추적 서비스 (호스트 끝부분)
    public static let trackerHosts = [
        "mailtrack.io", "mailstat.us", "yesware.com", "bananatag.com", "getnotify.com", "mailfoogae.appspot.com",
        "pixel.mailchimp.com", "list-manage.com", "mandrillapp.com", "sendgrid.net", "mailgun.org",
        "hubspotemail.net", "hs-analytics.net", "track.hubspot.com", "mixmax.com", "streak.com", "saleshandy.com",
        "mailtrack.co", "cirrusinsight.com", "outreach.io", "salesloft.com", "litmus.com", "emltrk.com",
        "signaturesatori.com", "returnpath.net", "exct.net", "pardot.com", "mktoresp.com",
        "stibee.com", "maily.so",
    ]

    /// 열람 추적에 흔한 경로
    static let trackerPaths = ["/track/open", "/wf/open", "/open.aspx", "/e/o/", "/o.gif", "/open.gif",
                               "/pixel", "/beacon", "/trk", "/tracking/open", "/emailopen"]

    /// 추적기로 보이는 주소인지
    public static func isTracker(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if trackerHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) || host.contains("sidekickopen") { return true }
        let path = url.path.lowercased()
        return trackerPaths.contains { path.contains($0) }
    }

    /// 1×1 같은 아주 작은 그림이거나 숨긴 그림이면 추적 픽셀로 본다.
    static func isPixel(tag: String) -> Bool {
        func size(_ name: String) -> Int? {
            let pattern = #"\b"# + name + #"\s*=\s*["']?\s*(\d+)"#
            guard let r = tag.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return Int(tag[r].filter(\.isNumber))
        }
        if let w = size("width"), w <= 2 { return true }
        if let h = size("height"), h <= 2 { return true }
        let style = tag.lowercased().replacingOccurrences(of: " ", with: "")
        return style.contains("display:none") || style.contains("visibility:hidden")
            || style.range(of: #"(width|height):[0-2]px"#, options: .regularExpression) != nil
    }

    /// 원격 주소 → 앱이 대신 받는 주소
    public static func proxyURL(for remote: URL) -> String {
        let encoded = remote.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "\(scheme)://image?u=\(encoded)"
    }

    /// 대신 받는 주소 → 원래 주소 (http, https만)
    public static func originalURL(from proxy: URL?) -> URL? {
        guard let proxy, proxy.scheme == scheme,
              let item = URLComponents(url: proxy, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" }),
              let value = item.value, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    public struct Result: Equatable, Sendable {
        public var html: String
        /// 뺀 추적기 수
        public var blocked: Int
        /// 대신 받을 그림 수
        public var proxied: Int
    }

    /// 본문의 원격 그림을 바꾼다: 추적기는 빼고, 나머지는 대신 받는 주소로. `srcset`은 지운다(대신 받지 않는 길이라서).
    public static func rewrite(html: String) -> Result {
        var blocked = 0, proxied = 0
        var out = html

        // <img ...> 태그
        out = replace(in: out, pattern: #"<img\b[^>]*>"#) { tag in
            let cleaned = tag.replacingOccurrences(of: #"\s+srcset\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "",
                                                   options: [.regularExpression, .caseInsensitive])
            guard let src = attribute("src", in: cleaned), let url = remoteURL(src) else { return cleaned }
            if isTracker(url) || isPixel(tag: cleaned) {
                blocked += 1
                return ""
            }
            proxied += 1
            return setAttribute("src", to: proxyURL(for: url), in: cleaned)
        }
        // background="..." 속성
        out = replace(in: out, pattern: #"\bbackground\s*=\s*("[^"]*"|'[^']*')"#) { attr in
            let value = String(attr.drop { $0 != "\"" && $0 != "'" }.dropFirst().dropLast())
            guard let url = remoteURL(value) else { return attr }
            if isTracker(url) { blocked += 1; return "" }
            proxied += 1
            return "background=\"\(proxyURL(for: url))\""
        }
        // CSS url(...)
        out = replace(in: out, pattern: #"url\(\s*(["']?)([^"')]+)\1\s*\)"#) { css in
            guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return css }
            let raw = css[css.index(after: open)..<close].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard let url = remoteURL(raw) else { return css }
            if isTracker(url) { blocked += 1; return "none" }
            proxied += 1
            return "url(\"\(proxyURL(for: url))\")"
        }
        return Result(html: out, blocked: blocked, proxied: proxied)
    }

    // MARK: helpers

    /// http(s) 또는 //로 시작하는 주소만 원격으로 본다. HTML 엔티티 &amp;는 풀어 둔다.
    static func remoteURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&")
        if s.hasPrefix("//") { s = "https:" + s }
        guard let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 2...4 {
            if let r = Range(m.range(at: group), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    static func setAttribute(_ name: String, to value: String, in tag: String) -> String {
        let pattern = #"\b"# + name + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return tag }
        let template = NSRegularExpression.escapedTemplate(for: "\(name)=\"\(value)\"")
        return re.stringByReplacingMatches(in: tag, range: NSRange(tag.startIndex..., in: tag), withTemplate: template)
    }

    static func replace(in text: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += transform(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
