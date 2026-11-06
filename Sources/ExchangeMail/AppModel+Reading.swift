import AppKit
import UniformTypeIdentifiers
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
            .appending(path: "FAKUKUMail-preview", directoryHint: .isDirectory)
            .appending(path: AttachmentDrag.folderName(attachment.id), directoryHint: .isDirectory)
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
        // 첨부된 메일(.eml)은 Quick Look 대신 이 앱의 창에서: 답장·전달할 수 있게 (1.0.1)
        if EMLMessage.isMail(name: full.name, contentType: full.contentType) {
            WindowOpener.shared.open(url)
            return
        }
        previewURL = url
    }

    /// 기본 앱으로 연다 (첨부 카드 > 열기).
    func openAttachment(_ attachment: FileAttachment, messageID: String? = nil) async {
        guard let full = await loadedAttachment(attachment, messageID: messageID),
              let url = previewFile(for: full) else { return }
        // 첨부된 메일(.eml)은 다른 메일 앱이 아니라 이 앱의 창에서 연다: 읽고 답장·전달할 수 있게 (1.0.1).
        if EMLMessage.isMail(name: full.name, contentType: full.contentType) {
            WindowOpener.shared.open(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 첨부 칩을 끌 때 (S-035): NFC 이름의 파일을 넘긴다. Finder에 놓으면 저장, 작성 창에 놓으면 첨부.
    /// 놓는 쪽은 메인 스레드를 멈추고 파일을 기다리므로, 여기서 서버에 물으면 서로 기다리며 앱이 멈춘다(무지개 휠).
    /// 그래서 이미 받아 둔 내용만 넘긴다: 메일을 열 때(`warmAttachments`)와 카드에 마우스를 올릴 때 미리 받는다.
    func dragProvider(for attachment: FileAttachment, messageID: String? = nil) -> NSItemProvider {
        // 카드가 가진 것보다 본문 목록에 이미 받아 둔 내용이 있으면 그것을
        let current = detailAttachments.first { $0.id == attachment.id && $0.data != nil } ?? attachment
        let name = FilenameEncoder.normalize(attachment.name)
        if current.data != nil, let url = previewFile(for: current) {
            return Self.fileDragProvider(url, name: name)
        }
        // 아직 받지 않았다: 놓을 때 메인 스레드 밖에서 서버에서 바로 받는다 (메인 스레드를 쓰면 놓는 쪽과 서로 기다려 멈춘다)
        let mid = messageID ?? detail?.id ?? ""
        if let request = directAttachmentRequest(messageID: mid, attachmentID: attachment.id) {
            warmAttachment(attachment, messageID: messageID)
            return AttachmentDrag.lazyProvider(request, name: name, folder: attachment.id)
        }
        NSLog("FAKUKU drag: %@ 내용 없음, 요청도 만들 수 없음", name)  // l10n: data
        warmAttachment(attachment, messageID: messageID)
        noticeMessage = L("\(attachment.name)을(를) 받는 중입니다. 잠시 뒤 다시 끌어 주세요.")
        return NSItemProvider()
    }

    /// 그 메일 계정의 Graph 첨부 요청 (Exchange만, 토큰이 남아 있을 때)
    func directAttachmentRequest(messageID: String, attachmentID: String) -> URLRequest? {
        guard let account = router.accountID(forMessage: messageID),
              let cached = router.service(forAccount: account) as? CachedMailService,
              let graph = cached.remote as? GraphMailService else { return nil }
        return graph.attachmentRequest(messageID: messageID, attachmentID: attachmentID)
    }

    /// 이미 있는 파일을 끌기로 넘긴다: 파일 주소(작성 창의 첨부 받기, Finder 복사)와 파일 내용(다른 앱) 둘 다.
    /// 둘 다 바로 내줄 수 있어 놓는 쪽이 기다려도 멈추지 않는다.
    static func fileDragProvider(_ url: URL, name: String) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        provider.suggestedName = name
        return provider
    }

    /// 작성 창에 파일 없는 끌기가 놓였을 때: 방금(1분 안) 마우스를 올린 받은 메일의 첨부를 받아 파일로 돌려준다.
    /// 놓기가 끝난 뒤에 부르므로 서버를 기다려도 멈추지 않는다.
    func droppedAttachmentFile() async -> URL? {
        guard let c = dragCandidate, Date().timeIntervalSince(c.at) < 60 else { return nil }
        NSLog("FAKUKU drop: 끌기에 파일이 없어 마우스를 올린 첨부를 넣는다 %@", c.attachment.name)  // l10n: data
        guard let full = await loadedAttachment(c.attachment, messageID: c.messageID) else { return nil }
        return previewFile(for: full)
    }

    /// 첨부 내용을 뒤에서 조용히 받아 둔다 (끌기를 바로 할 수 있게). 이미 있거나 받는 중이면 하지 않는다.
    func warmAttachment(_ attachment: FileAttachment, messageID: String? = nil) {
        guard attachment.data == nil, !(attachment.odataType ?? "").hasSuffix("referenceAttachment"),
              !detailAttachments.contains(where: { $0.id == attachment.id && $0.data != nil }),
              !warmingAttachments.contains(attachment.id) else { return }
        warmingAttachments.insert(attachment.id)
        Task {
            _ = await loadedAttachment(attachment, messageID: messageID, quiet: true)
            warmingAttachments.remove(attachment.id)
        }
    }

    /// 메일을 열면 작은 첨부(하나 10MB, 모두 30MB까지)를 차례로 받아 둔다.
    /// 로그인 토큰도 새로 고쳐 둔다: 아직 못 받은 큰 첨부를 끌면 놓을 때 그 토큰으로 바로 받는다 (AttachmentDrag).
    func warmAttachments(_ list: [FileAttachment], messageID: String) {
        if list.contains(where: { $0.isInline != true }) {
            Task { _ = try? await accounts.accounts.first { $0.id == router.accountID(forMessage: messageID) }?.auth.validAccessToken() }
        }
        var budget = 30 * 1024 * 1024
        for a in list where a.isInline != true && a.data == nil {
            let size = a.size ?? Int.max
            guard size <= 10 * 1024 * 1024, size <= budget else { continue }
            budget -= size
            warmAttachment(a, messageID: messageID)
        }
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

/// 끌기 공급자 (메인 액터 밖): 놓는 쪽은 메인 스레드를 멈추고 기다리므로, 여기 일은 메인 스레드를 쓰지 않는다.
nonisolated enum AttachmentDrag {
    /// 첨부마다 다른 임시 폴더 이름. Exchange 첨부 id는 앞부분이 메일함 전체에서 같아서 앞 64글자로 자르면
    /// 다른 메일의 같은 이름 첨부가 같은 파일을 덮어썼다 (작성 중인 메일의 첨부가 바뀔 수 있었다). id 전체의 해시를 쓴다.
    static func folderName(_ id: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a 64
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// 놓을 때 서버에서 받아 임시 파일로 쓰고 그 파일을 넘긴다 (파일 주소와 파일 내용 둘 다)
    static func lazyProvider(_ request: URLRequest, name: String, folder: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "FAKUKUMail-preview", directoryHint: .isDirectory)
            .appending(path: folderName(folder), directoryHint: .isDirectory)
        let target = dir.appending(path: name)
        let fetch: @Sendable () async throws -> URL = {
            if FileManager.default.fileExists(atPath: target.path) { return target }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        }
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            Task.detached {
                do { completion(try await fetch() as NSURL, nil) } catch {
                    NSLog("FAKUKU drag: 받기 실패 %@", error.localizedDescription)  // l10n: data
                    completion(nil, error)
                }
            }
            return nil
        }
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task.detached {
                do { completion(try await fetch(), false, nil) } catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }
}
