import AppKit
import SwiftUI
import WebKit

/// 받은 메일 본문. JavaScript는 끄고, 원격 이미지는 CSP로 막고(MailContent.page), 링크는 기본 브라우저로 연다.
struct HTMLView: NSViewRepresentable {
    let html: String
    var onMailto: (URL) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onMailto = onMailto
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
