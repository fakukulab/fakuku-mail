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

    /// Quick Look으로 연다. 내용이 빠진 첨부는 서버에서 받아 온다.
    func preview(_ attachment: FileAttachment, messageID: String? = nil) async {
        guard let full = await loadedAttachment(attachment, messageID: messageID),
              let url = previewFile(for: full) else {
            if errorMessage == nil {
                errorMessage = isOffline ? L("오프라인이라 이 첨부를 열 수 없습니다. 연결되면 다시 해 주세요.")
                                         : L("이 첨부를 열 수 없습니다.")
            }
            return
        }
        previewURL = url
    }

    /// 기본 앱으로 연다 (첨부 카드 > 열기).
    func openAttachment(_ attachment: FileAttachment, messageID: String? = nil) async {
        guard let full = await loadedAttachment(attachment, messageID: messageID),
              let url = previewFile(for: full) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 첨부 칩을 Finder로 끌 때 (S-035): NFC 이름의 파일을 넘긴다.
    func dragProvider(for attachment: FileAttachment) -> NSItemProvider {
        // 내용이 아직 없으면 받아 두기 시작한다 (다음 끌기부터 파일이 나간다).
        if attachment.data == nil { Task { _ = await loadedAttachment(attachment) } }
        guard let url = previewFile(for: attachment), let provider = NSItemProvider(contentsOf: url) else {
            return NSItemProvider()
        }
        provider.suggestedName = FilenameEncoder.normalize(attachment.name)
        return provider
    }

    /// 메시지 > 첨부 훑어보기 (⌘Y): 첫 첨부
    func previewFirstAttachment() {
        if let first = listedAttachments.first { Task { await preview(first) } }
    }

    // MARK: 인쇄 (S-034)

    /// 지금 보는 메일을 머리글과 함께 인쇄한다. 인쇄 창에서 PDF로 저장할 수도 있다.
    func printDisplayed() {
        guard let m = detail else { return }
        printMessage(m, body: detailBody, remote: detailRemote)
    }

    /// 메일 한 통을 인쇄한다 (본문 열 또는 메시지 창, S-043). 원격 그림은 화면과 같은 방식으로 (S-047).
    func printMessage(_ m: MailMessage, body: MailMessage.Body?, remote: RemoteContent) {
        let html = MailContent.printPage(message: m, body: body, remote: remote)
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
        config.setURLSchemeHandler(ProxyImageLoader.shared, forURLScheme: TrackingProtection.scheme)
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
