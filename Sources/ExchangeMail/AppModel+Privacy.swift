import ExchangeMailKit
import Foundation
import WebKit

/// 본문 문서와 그 안에서 막은 추적기 수 (S-047)
struct ProtectedPage {
    var html: String
    var blockedTrackers: Int
}

/// 메일 활동 보호 (S-047): 메일마다 원격 콘텐츠를 어떻게 보일지.
extension AppModel {

    /// 정크 메일 폴더 id
    var junkFolderIDs: Set<String> {
        Set(folders.filter { $0.kind == "junkemail" }.map(\.id) + ["junkemail"])
    }

    /// 이 메일의 원격 콘텐츠 방식. "불러오기"를 눌렀으면 그대로, 정크 메일은 막고, 아니면 설정대로.
    func remoteMode(for m: MailMessage?, allowed: Bool) -> RemoteContent {
        if allowed { return .allowed }
        if junkBlocksRemote, let folder = m?.parentFolderId, junkFolderIDs.contains(folder) { return .blocked }
        if protectMailActivity { return .proxied }
        return blockAllRemote ? .blocked : .allowed
    }

    /// 본문 열의 방식
    var detailRemote: RemoteContent {
        var m = detail
        // 목록에서 고른 폴더가 정크면 메일의 폴더 값이 없어도 정크로 본다.
        if m?.parentFolderId == nil, selectedFolder?.kind == "junkemail" { m?.parentFolderId = selectedFolderID }
        return remoteMode(for: m, allowed: remoteContentAllowed)
    }

    /// 웹 보기에 넣을 문서. 같은 메일·같은 방식이면 다시 만들지 않는다.
    func protectedPage(id: String?, body: MailMessage.Body?, remote: RemoteContent) -> ProtectedPage {
        let key = "\(id ?? "")|\(remote.rawValue)|\(body?.content.count ?? 0)"
        if let hit = pageCache[key] { return hit }
        let blocked = remote == .proxied && body?.isHTML == true
            ? TrackingProtection.rewrite(html: body?.content ?? "").blocked : 0
        let page = ProtectedPage(html: MailContent.page(body: body, remote: remote), blockedTrackers: blocked)
        if pageCache.count > 24 { pageCache.removeAll() }
        pageCache[key] = page
        return page
    }
}

/// `fakuku-proxy://image?u=<원래 주소>` 그림을 대신 받는다 (S-047).
/// 쿠키를 보내지도 받지도 않고, 리퍼러를 붙이지 않고, 흔한 브라우저처럼 보이는 User-Agent를 쓴다.
/// 그림(image/*)이 아니거나 10 MB를 넘으면 버린다.
final class ProxyImageLoader: NSObject, WKURLSchemeHandler {
    static let shared = ProxyImageLoader()
    static let maxBytes = 10 * 1024 * 1024

    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0)
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            "Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8",
        ]
        return URLSession(configuration: c)
    }()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let target = TrackingProtection.originalURL(from: urlSchemeTask.request.url),
              let own = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let session = self.session
        running[key] = Task { @MainActor [weak self] in
            var request = URLRequest(url: target, cachePolicy: .returnCacheDataElseLoad)
            request.setValue(nil, forHTTPHeaderField: "Referer")
            let result: Result<(Data, URLResponse), Error>
            do {
                result = .success(try await session.data(for: request))
            } catch {
                result = .failure(error)
            }
            // 웹 보기가 멈추라고 했으면(다른 메일로 옮김) 아무것도 돌려주지 않는다.
            guard let self, self.running.removeValue(forKey: key) != nil else { return }
            switch result {
            case .success(let (data, response)):
                let mime = response.mimeType?.lowercased() ?? ""
                guard mime.hasPrefix("image/"), data.count <= Self.maxBytes else {
                    urlSchemeTask.didFailWithError(URLError(.cannotDecodeContentData))
                    return
                }
                urlSchemeTask.didReceive(URLResponse(url: own, mimeType: mime, expectedContentLength: data.count,
                                                     textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let error):
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
