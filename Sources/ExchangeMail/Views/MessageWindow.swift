import ExchangeMailKit
import QuickLook
import SwiftUI

/// 메일 한 통을 독립 창으로 (S-043). 목록에서 두 번 클릭, Return, 메시지 > 새 창에서 열기(⌘O).
struct MessageWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var reader: MessageReader
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

    init(messageID: String) {
        _reader = State(initialValue: MessageReader(messageID: messageID))
    }

    var body: some View {
        Group {
            if let m = reader.message {
                VStack(alignment: .leading, spacing: 0) {
                    MessageHeader(message: m, attachments: reader.listedAttachments) { reader.preview($0, model: model) }
                    UnsubscribeBar(message: m)
                    let remote = model.remoteMode(for: m, allowed: reader.allowRemote)
                    let page = model.protectedPage(id: m.id, body: reader.body, remote: remote, css: readingStyle.css)
                    if reader.hasRemoteContent {
                        RemoteContentBar(remote: remote, blockedTrackers: page.blockedTrackers) { reader.allowRemoteContent() }
                    }
                    Divider()
                    HTMLView(html: page.html,
                             scroller: reader.pageScroller, onPrint: { reader.print(model: model) }) { url in
                        openWindow(id: "compose", value: ComposeDraft.mailto(url))
                    }
                }
            } else if let failure = reader.failure {
                ContentUnavailableView(L("메일을 열 수 없습니다"), systemImage: "envelope.badge.shield.half.filled",
                                       description: Text(failure))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(reader.message?.title ?? L("메시지"))
        .navigationSubtitle(reader.message?.from?.emailAddress.display ?? "")
        .toolbar(id: "message") {
            replyItems
            organizeItems
        }
        .onDeleteCommand { Task { await reader.move(to: "deleteditems", undoName: L("지우기"), model: model) } }
        .quickLookPreview($reader.previewURL)
        // 메시지 메뉴(답장, 보관, 인쇄…)가 이 창이 앞에 있을 때 이 메일에 동작한다.
        .focusedSceneValue(\.messageReader, reader)
        .task { await reader.load(using: model) }
        .onChange(of: reader.closed) { _, closed in
            if closed { dismiss() }
        }
        .noInitialFocus()
    }

    @ToolbarContentBuilder
    private var replyItems: some CustomizableToolbarContent {
        ToolbarItem(id: "reply") {
            Button(L("답장"), systemImage: "arrowshape.turn.up.left") { compose(.reply) }
                .help(L("답장 (⌘R)"))
                .disabled(reader.message == nil)
        }
        ToolbarItem(id: "replyAll") {
            Button(L("전체 답장"), systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll) }
                .help(L("전체 답장 (⇧⌘R)"))
                .disabled(reader.message == nil)
        }
        ToolbarItem(id: "forward") {
            Button(L("전달"), systemImage: "arrowshape.turn.up.right") { compose(.forward) }
                .help(L("전달 (⇧⌘F)"))
                .disabled(reader.message == nil)
        }
        ToolbarSpacer(.flexible)
    }

    @ToolbarContentBuilder
    private var organizeItems: some CustomizableToolbarContent {
        ToolbarItem(id: "flag") {
            Menu {
                FlagColorItems { color in Task { await reader.setFlagColor(color, model: model) } }
            } label: {
                Label(reader.message?.isFlagged == true ? L("깃발 떼기") : L("깃발 달기"),
                      systemImage: reader.message?.isFlagged == true ? "flag.fill" : "flag")
            } primaryAction: {
                Task { await reader.toggleFlag(model: model) }
            }
            .help(L("깃발 달기/떼기 (⇧⌘L), 색은 ⌄"))
            .disabled(reader.message == nil)
        }
        ToolbarItem(id: "archive") {
            Button(L("보관"), systemImage: "archivebox") {
                Task { await reader.move(to: "archive", undoName: L("보관"), model: model) }
            }
            .help(L("보관하고 창을 닫습니다 (⌃⌘A)"))
            .disabled(reader.message == nil)
        }
        ToolbarItem(id: "delete") {
            Button(L("지우기"), systemImage: "trash") {
                Task { await reader.move(to: "deleteditems", undoName: L("지우기"), model: model) }
            }
            .help(L("지우고 창을 닫습니다 (Delete)"))
            .disabled(reader.message == nil)
        }
        ToolbarItem(id: "print") {
            Button(L("인쇄"), systemImage: "printer") { reader.print(model: model) }
                .help(L("인쇄 (⌘P)"))
                .disabled(reader.message == nil)
        }
    }

    private func compose(_ kind: ComposeKind) {
        if let draft = reader.draft(kind, model: model) { openWindow(id: "compose", value: draft) }
    }
}
