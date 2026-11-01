import AppKit
import SwiftUI
import WebKit

/// 받은 메일 본문. JavaScript는 끄고, 원격 이미지는 CSP로 막고(MailContent.page), 링크는 기본 브라우저로 연다.
struct HTMLView: NSViewRepresentable {
    let html: String
    /// 목록에서 Space로 본문을 넘길 때 쓴다 (S-019).
    var scroller: PageScroller? = nil
    /// 이 웹 보기에 인쇄 명령이 오면 대신 부른다 (머리글이 붙은 인쇄, S-034).
    var onPrint: (() -> Void)? = nil
    var onMailto: (URL) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let wv = MailWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        wv.onPrint = onPrint
        scroller?.webView = wv
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onMailto = onMailto
        (nsView as? MailWebView)?.onPrint = onPrint
        scroller?.webView = nsView
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        nsView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var onMailto: (URL) -> Void = { _ in }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                // loadHTMLString으로 넣은 본문(about:blank)만 허용한다.
                // meta refresh, 폼, 리디렉션 같은 다른 이동은 모두 막는다.
                let target = navigationAction.request.url?.absoluteString ?? ""
                decisionHandler(target.isEmpty || target.hasPrefix("about:") ? .allow : .cancel)
                return
            }
            if url.scheme?.lowercased() == "mailto" {
                onMailto(url)
            } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

/// 본문 웹 보기를 한 쪽씩 넘긴다 (S-019). 목록에 초점이 있어도 Space로 본문을 읽게 한다.
/// 메일 HTML의 JavaScript는 꺼져 있지만, 앱이 별도 content world에서 부르는 스크립트는 돈다.
final class PageScroller {
    weak var webView: WKWebView?

    /// 한 쪽 내리거나 올린다. 이미 끝(또는 처음)이었으면 true: 호출한 쪽이 다음 메일로 넘어간다.
    func page(down: Bool) async -> Bool {
        guard let webView else { return true }
        let body = """
        const el = document.scrollingElement || document.documentElement;
        const step = Math.max(window.innerHeight * 0.9, 40);
        const atEdge = down ? (el.scrollTop + window.innerHeight >= el.scrollHeight - 2) : (el.scrollTop <= 0);
        if (!atEdge) { window.scrollBy({ top: down ? step : -step, behavior: 'smooth' }); }
        return atEdge;
        """
        do {
            let result = try await webView.callAsyncJavaScript(body, arguments: ["down": down], in: nil, contentWorld: .defaultClient)
            return (result as? Bool) ?? false
        } catch {
            return false
        }
    }
}

/// 본문 웹 보기. ⌘P나 인쇄 명령이 메뉴를 지나 이 보기까지 오면 NSView 기본 인쇄(본문만)가 아니라
/// 머리글이 붙은 앱의 인쇄로 보낸다 (S-034).
final class MailWebView: WKWebView {
    var onPrint: (() -> Void)?

    override func print(_ sender: Any?) {
        if let onPrint { onPrint() } else { super.print(sender) }
    }
}
