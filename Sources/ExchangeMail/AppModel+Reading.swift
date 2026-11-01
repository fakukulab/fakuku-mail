import AppKit
import ExchangeMailKit
import Foundation
import WebKit

/// 읽기 (M10): 첨부 미리보기, 인쇄.
extension AppModel {

    // MARK: 첨부 미리보기 (S-032)

    /// 첨부를 임시 폴더에 NFC 이름으로 써서 그 주소를 돌려준다. 내용이 없으면(큰 첨부를 오프라인에서 등) nil.
    func previewFile(for attachment: FileAttachment) -> URL? {
        guard let data = attachment.data else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ExchangeMail-preview", directoryHint: .isDirectory)
            .appending(path: attachment.id.replacingOccurrences(of: "/", with: "_").prefix(64).description, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: FilenameEncoder.normalize(attachment.name))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    /// Quick Look으로 연다.
    func preview(_ attachment: FileAttachment) {
        guard let url = previewFile(for: attachment) else {
            errorMessage = isOffline
                ? "오프라인이라 이 첨부를 열 수 없습니다. 연결되면 다시 해 주세요."
                : "이 첨부는 파일이 아니라서 미리 볼 수 없습니다."
            return
        }
        previewURL = url
    }

    /// 메시지 > 첨부 훑어보기 (⌘Y): 첫 첨부
    func previewFirstAttachment() {
        if let first = listedAttachments.first { preview(first) }
    }

    // MARK: 인쇄 (S-034)

    /// 지금 보는 메일을 머리글과 함께 인쇄한다. 인쇄 창에서 PDF로 저장할 수도 있다.
    func printDisplayed() {
        guard let m = detail else { return }
        let html = MailContent.printPage(message: m, body: detailBody, allowRemote: remoteContentAllowed)
        let printer = MailPrinter()
        self.printer = printer
        printer.print(html: html, title: m.title) { [weak self] in self?.printer = nil }
    }
}

/// 화면 밖 웹 보기에 인쇄용 문서를 그려 인쇄 창을 연다 (S-034).
final class MailPrinter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var title = ""
    private var done: (() -> Void)?

    func print(html: String, title: String, done: @escaping () -> Void) {
        self.title = title
        self.done = done
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        // A4 폭쯤. 인쇄 작업이 쪽 나누기를 다시 한다.
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 1000), configuration: config)
        wv.navigationDelegate = self
        webView = wv
        wv.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .spool
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = webView.bounds
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            // 인쇄 시트는 비동기로 열린다. 이 객체(와 웹 보기)는 다음 인쇄까지 AppModel이 잡아 둔다.
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
            done?()
            done = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done?()
        done = nil
    }
}
