import AppKit
import ExchangeMailKit
import Observation
import SwiftUI

/// .eml 파일 한 통 (1.0.1): 받은 메일에 첨부된 메일, 나의 Mac에 메일의 첨부, Finder에서 연 .eml.
/// 맥 Mail처럼 앱 안의 창에서 읽고, 답장·전체 답장·전달하거나 새 메시지로 편집한다. 서버에 닿지 않는다.
@Observable
final class EMLDocument {
    let url: URL
    private(set) var mail: ArchivedMail?
    /// 열지 못했을 때 창에 보일 이유
    private(set) var failure: String?

    init(url: URL) {
        self.url = url
    }

    var title: String { mail?.title ?? url.deletingPathExtension().lastPathComponent }

    func load() async {
        guard mail == nil else { return }
        let url = self.url
        do {
            let mails = try await Task.detached { try ArchiveFile.load(url) }.value
            if let first = mails.first {
                mail = first
                failure = nil
            } else {
                failure = L("\"\(url.lastPathComponent)\"에서 메일을 찾지 못했습니다.")
            }
        } catch {
            failure = L("파일을 읽지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 답장·전체 답장·전달·새 메시지로 편집(.new)의 시작 값. 보낼 계정은 지금 계정.
    func draft(_ kind: ComposeKind, model: AppModel) -> ComposeDraft? {
        guard let mail else { return nil }
        var d = EMLMessage.draft(kind: kind, mail: mail, myAddress: model.accounts.active?.email ?? model.auth.email)
        // 설정 > 작성 > "원본 메시지의 텍스트를 인용"을 끄면 답장에 원문을 넣지 않는다 (전달은 늘 넣는다).
        if (kind == .reply || kind == .replyAll) && !Prefs.bool(Prefs.quoteOriginal, true) { d.quoteHTML = "" }
        // 전달과 새 메시지로 편집은 첨부도 옮긴다 (본문 그림은 본문 안에 들어 있다).
        if kind == .forward || kind == .new {
            d.attachFiles = mail.attachments.filter { !$0.isInline }.compactMap(ArchivedFiles.tempFile)
        }
        return d
    }
}

/// .eml 창 (WindowGroup "eml"). 머리글·첨부·본문은 나의 Mac에 메일과 같은 `ArchivedMailView`.
struct EMLWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var document: EMLDocument
    // 설정 > 서체 및 색상
    @AppStorage(Prefs.bodyFontFamily) private var bodyFamily = ""
    @AppStorage(Prefs.bodyFontSize) private var bodySize = 14
    @AppStorage(Prefs.plainMonospace) private var plainMonospace = false
    @AppStorage(Prefs.quoteColors) private var quoteColors = true
    @AppStorage(Prefs.quoteColor1) private var quote1 = Prefs.defaultQuoteColors[0]
    @AppStorage(Prefs.quoteColor2) private var quote2 = Prefs.defaultQuoteColors[1]
    @AppStorage(Prefs.quoteColor3) private var quote3 = Prefs.defaultQuoteColors[2]

    private var readingStyle: ReadingStyle {
        ReadingStyle(family: bodyFamily, size: bodySize, plainMonospace: plainMonospace, quoteColors: quoteColors,
                     quote: [quote1, quote2, quote3])
    }

    init(url: URL) {
        _document = State(initialValue: EMLDocument(url: url))
    }

    var body: some View {
        Group {
            if let mail = document.mail {
                ArchivedMailView(mail: mail, css: readingStyle.css)
            } else if let failure = document.failure {
                ContentUnavailableView(L("메일을 열 수 없습니다"), systemImage: "envelope.badge.shield.half.filled",
                                       description: Text(failure))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(document.title)
        .navigationSubtitle(document.mail.map { MailArchive.displayName($0.from) } ?? "")
        .toolbar(id: "eml") {
            ToolbarItem(id: "reply") {
                Button(L("답장"), systemImage: "arrowshape.turn.up.left") { compose(.reply) }
                    .help(L("답장 (⌘R)"))
                    .disabled(!canCompose)
            }
            ToolbarItem(id: "replyAll") {
                Button(L("전체 답장"), systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll) }
                    .help(L("전체 답장 (⇧⌘R)"))
                    .disabled(!canCompose)
            }
            ToolbarItem(id: "forward") {
                Button(L("전달"), systemImage: "arrowshape.turn.up.right") { compose(.forward) }
                    .help(L("전달 (⇧⌘F)"))
                    .disabled(!canCompose)
            }
            ToolbarItem(id: "editAsNew") {
                Button(L("새 메시지로 편집"), systemImage: "square.and.pencil") { compose(.new) }
                    .help(L("받는 사람·제목·본문·첨부를 옮긴 새 메시지 (⌥⌘D)"))
                    .disabled(!canCompose)
            }
        }
        // 메시지 메뉴(답장, 전달…)가 이 창이 앞에 있을 때 이 메일에 동작한다.
        .focusedSceneValue(\.emlDocument, document)
        .task {
            WindowOpener.shared.attach(openWindow)
            await document.load()
        }
        .noInitialFocus()
    }

    /// 보낼 계정이 있어야 답장·전달할 수 있다 (읽기는 로그인하지 않아도 된다).
    private var canCompose: Bool { document.mail != nil && model.isSignedIn }

    private func compose(_ kind: ComposeKind) {
        if let draft = document.draft(kind, model: model) { openWindow(id: "compose", value: draft) }
    }
}

nonisolated struct EMLDocumentKey: FocusedValueKey {
    typealias Value = EMLDocument
}

extension FocusedValues {
    /// 앞에 있는 .eml 창의 메일. 메시지 메뉴의 답장·전달이 이 메일에 동작한다 (1.0.1).
    nonisolated var emlDocument: EMLDocument? {
        get { self[EMLDocumentKey.self] }
        set { self[EMLDocumentKey.self] = newValue }
    }
}

/// 모델이나 앱 델리게이트처럼 `openWindow`가 없는 곳에서 창을 연다 (1.0.1):
/// Finder에서 연 .eml, 다른 앱의 mailto: 링크(기본 이메일 앱일 때), 받은 메일의 .eml 첨부 열기.
/// 창이 하나 뜨면 그 창의 `openWindow`를 받아 둔다. 그 전에 온 요청은 모아 두었다가 연다.
final class WindowOpener {
    static let shared = WindowOpener()
    private var action: OpenWindowAction?
    private var pending: [URL] = []

    func attach(_ action: OpenWindowAction) {
        self.action = action
        let waiting = pending
        pending = []
        for url in waiting { open(url) }
    }

    /// mailto: 링크는 작성 창, 메일 파일(.eml, .emlx)은 .eml 창으로
    func open(_ url: URL) {
        guard let action else {
            pending.append(url)
            return
        }
        if url.scheme?.lowercased() == "mailto" {  // l10n: data
            action(id: "compose", value: ComposeDraft.mailto(url))
        } else if url.isFileURL {
            action(id: "eml", value: url)
        }
    }
}
