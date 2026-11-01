import Foundation

/// 본문 HTML에서 꺼낸 data: 이미지 하나.
public struct ExtractedImage: Equatable, Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    /// nil이면 일반 첨부, 값이 있으면 `cid:`로 본문에 남는 인라인 이미지.
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String?) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

public struct HTMLProcessResult: Sendable {
    public var html: String
    public var images: [ExtractedImage]
}

/// 보낼 본문 HTML을 다듬는다 (기획안 F1, F2).
/// - 서명(`data-signature`)과 인용문(`data-quote`) 안 이미지 → 인라인(cid) 유지
/// - 그 밖의 본문 이미지 → 일반 첨부로 빼고 `<img>`를 지운다 (설정으로 끌 수 있음)
public enum HTMLProcessor {

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // 패턴은 모두 이 파일의 상수라서 실패하지 않는다.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static var imgRegex: NSRegularExpression {
        regex(#"<img\b[^>]*>"#, [.caseInsensitive, .dotMatchesLineSeparators])
    }
    private static var srcRegex: NSRegularExpression {
        regex(#"\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    }
    private static var nameRegex: NSRegularExpression {
        regex(#"\b(?:data-filename|alt|title)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    }
    private static var dataURIRegex: NSRegularExpression {
        regex(#"^data:([\w/+.-]+);base64,(.*)$"#, [.caseInsensitive, .dotMatchesLineSeparators])
    }

    /// 정규식의 첫 번째(또는 두 번째) 캡처 그룹 값.
    static func firstGroup(_ re: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        return nil
    }

    struct DataURI { var mimeType: String; var data: Data }

    static func decodeDataURI(_ src: String) -> DataURI? {
        let ns = src as NSString
        guard let m = dataURIRegex.firstMatch(in: src, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let mime = ns.substring(with: m.range(at: 1)).lowercased()
        let b64 = ns.substring(with: m.range(at: 2)).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return DataURI(mimeType: mime, data: data)
    }

    /// `<div ... data-signature ...> ... </div>` 같은 블록의 범위들 (중첩 div 고려).
    public static func blockRanges(in html: String, attribute: String) -> [Range<String.Index>] {
        let open = regex("<div\\b[^>]*\\b\(NSRegularExpression.escapedPattern(for: attribute))\\b[^>]*>")
        var ranges: [Range<String.Index>] = []
        var searchStart = html.startIndex
        while searchStart < html.endIndex,
              let m = open.firstMatch(in: html, range: NSRange(searchStart..<html.endIndex, in: html)),
              let openRange = Range(m.range, in: html) {
            var depth = 1
            var pos = openRange.upperBound
            var end = html.endIndex
            while depth > 0, pos < html.endIndex {
                let rest = pos..<html.endIndex
                guard let close = html.range(of: "</div", options: .caseInsensitive, range: rest) else { break }
                if let next = html.range(of: "<div", options: .caseInsensitive, range: rest),
                   next.lowerBound < close.lowerBound {
                    depth += 1
                    pos = next.upperBound
                } else {
                    depth -= 1
                    pos = html[close.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                    if depth == 0 { end = pos }
                }
            }
            ranges.append(openRange.lowerBound..<end)
            searchStart = end
        }
        return ranges
    }

    public static func signatureRanges(in html: String) -> [Range<String.Index>] {
        blockRanges(in: html, attribute: "data-signature")
    }

    /// 인라인으로 남겨야 하는 영역: 서명과 인용문.
    static func inlineRanges(in html: String) -> [Range<String.Index>] {
        signatureRanges(in: html) + blockRanges(in: html, attribute: "data-quote")
    }

    /// 보정을 켜면 일반 첨부로 나갈 본문 이미지 수. 작성 창 안내 문구용이라 디코딩하지 않는다.
    public static func bodyImageCount(in html: String) -> Int {
        let keep = inlineRanges(in: html)
        let ns = html as NSString
        return imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)).filter { m in
            let tag = ns.substring(with: m.range)
            guard let src = firstGroup(srcRegex, in: tag), src.lowercased().hasPrefix("data:"),
                  let start = Range(m.range, in: html)?.lowerBound else { return false }
            return !keep.contains { $0.contains(start) }
        }.count
    }

    public static func process(html: String, convertBodyImagesToAttachments: Bool,
                               minInlineBytes: Int = 0) -> HTMLProcessResult {
        let keep = inlineRanges(in: html)
        let ns = html as NSString
        var out = ""
        var cursor = 0
        var images: [ExtractedImage] = []
        var counter = 0
        let runID = UUID().uuidString.prefix(8)

        for m in imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let src = firstGroup(srcRegex, in: tag),
                  let uri = decodeDataURI(src),
                  let tagStart = Range(m.range, in: html)?.lowerBound else { continue }

            counter += 1
            let ext = fileExtension(for: uri.mimeType)
            var name = "image\(counter).\(ext)"
            if let given = firstGroup(nameRegex, in: tag).map(unescapeEntities), !given.isEmpty {
                name = given.contains(".") ? given : "\(given).\(ext)"
            }
            name = FilenameEncoder.normalize(name)

            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = NSMaxRange(m.range)

            let inKeptBlock = keep.contains { $0.contains(tagStart) }
            let keepInline = inKeptBlock || !convertBodyImagesToAttachments || uri.data.count < minInlineBytes
            if keepInline {
                let cid = "img\(counter).\(runID)@exchangemail"
                images.append(ExtractedImage(filename: name, mimeType: uri.mimeType, data: uri.data, contentID: cid))
                let tns = tag as NSString
                out += srcRegex.stringByReplacingMatches(in: tag, range: NSRange(location: 0, length: tns.length),
                                                         withTemplate: "src=\"cid:\(cid)\"")
            } else {
                // <img>는 지우고 첨부로 옮긴다.
                images.append(ExtractedImage(filename: name, mimeType: uri.mimeType, data: uri.data, contentID: nil))
            }
        }
        out += ns.substring(from: cursor)
        return HTMLProcessResult(html: out, images: images)
    }

    static func fileExtension(for mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/heic": "heic"
        case "image/webp": "webp"
        case "image/svg+xml": "svg"
        case "image/bmp": "bmp"
        case "image/tiff": "tiff"
        default: "bin"
        }
    }

    static func unescapeEntities(_ s: String) -> String {
        var r = s
        for (a, b) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            r = r.replacingOccurrences(of: a, with: b)
        }
        return r
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 단순한 HTML → 평문 (text/plain 대체 본문용).
    public static func plainText(from html: String) -> String {
        var s = html
        for (pattern, replacement) in [(#"(?is)<(style|script|head)\b.*?</\1>"#, ""),
                                       (#"(?i)<br\s*/?>"#, "\n"),
                                       (#"(?i)</(p|div|li|tr|h[1-6]|blockquote)>"#, "\n"),
                                       (#"<[^>]+>"#, ""),
                                       (#"\n{3,}"#, "\n\n")] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return unescapeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
