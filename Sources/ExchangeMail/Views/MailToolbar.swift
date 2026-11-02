import ExchangeMailKit
import SwiftUI

/// 메인 창의 도구 막대 (S-044). 보기 > 도구 막대 사용자화…로 넣고 뺀다.
/// NavigationSplitView 자체에 한 번만 단다: 열마다 따로 달거나 일반 `.toolbar {}` 항목이 섞이면
/// macOS가 창 전체의 사용자화를 끈다.
extension MailSplitView {
    @ToolbarContentBuilder
    var mailToolbar: some CustomizableToolbarContent {
        list
        ToolbarSpacer(.flexible)
        organize
        ToolbarSpacer(.fixed)
        reply
        extras
    }

    @ToolbarContentBuilder
    private var list: some CustomizableToolbarContent {
        ToolbarItem(id: "filter") { FilterMenu(model: model) }
        ToolbarItem(id: "sort") { SortMenu(model: model) }
        ToolbarItem(id: "listGetMail") {
            Button("받은 메일 가져오기", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("받은 메일 가져오기 (⇧⌘N)")
        }
        ToolbarItem(id: "listNewMessage") {
            Button("새로운 메시지", systemImage: "square.and.pencil") { openWindow(id: "compose", value: ComposeDraft()) }
                .help("새로운 메시지 (⌘N)")
        }
    }

    private var noSelection: Bool { model.selectedIDs.isEmpty }

    @ToolbarContentBuilder
    private var organize: some CustomizableToolbarContent {
        ToolbarItem(id: "archive") {
            Button("보관", systemImage: "archivebox") { Task { await model.archiveSelected(undoManager: undoManager) } }
                .help("보관 (⌃⌘A)")
                .disabled(noSelection)
        }
        ToolbarItem(id: "delete") {
            Button("지우기", systemImage: "trash") { Task { await model.deleteSelected(undoManager: undoManager) } }
                .help("지우기 (Delete)")
                .disabled(noSelection)
        }
        ToolbarItem(id: "junk") {
            Button("정크", systemImage: "xmark.bin") { Task { await model.toggleJunkSelected(undoManager: undoManager) } }
                .help("정크 메일로 표시 / 정크 아님 (⇧⌘J)")
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "move") {
            Button("이동", systemImage: "folder") { model.showMovePicker = true }
                .help("다른 폴더로 이동 (⇧⌘M)")
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "flag") {
            Button("깃발", systemImage: "flag") { Task { await model.toggleFlagSelected() } }
                .help("깃발 달기/떼기 (⇧⌘L)")
                .disabled(noSelection)
        }
    }

    @ToolbarContentBuilder
    private var reply: some CustomizableToolbarContent {
        ToolbarItem(id: "reply") {
            Button("답장", systemImage: "arrowshape.turn.up.left") { compose(.reply) }
                .help("답장 (⌘R)")
                .disabled(model.detail == nil)
        }
        ToolbarItem(id: "replyAll") {
            Button("전체 답장", systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll) }
                .help("전체 답장 (⇧⌘R)")
                .disabled(model.detail == nil)
        }
        ToolbarItem(id: "forward") {
            Button("전달", systemImage: "arrowshape.turn.up.right") { compose(.forward) }
                .help("전달 (⇧⌘F)")
                .disabled(model.detail == nil)
        }
    }

    /// 처음에는 숨겨 두고 사용자화 시트에서 끌어 넣는 항목
    @ToolbarContentBuilder
    private var extras: some CustomizableToolbarContent {
        ToolbarItem(id: "read") {
            Button("읽음/읽지 않음", systemImage: "envelope.badge") { Task { await model.toggleReadSelected() } }
                .help("읽음 또는 읽지 않음으로 표시 (⇧⌘U)")
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "print") {
            Button("인쇄", systemImage: "printer") { model.printDisplayed() }
                .help("인쇄 (⌘P)")
                .disabled(model.detail == nil || model.multipleSelectionCount > 0)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "openWindow") {
            Button("새 창에서 열기", systemImage: "macwindow.on.rectangle") { openInWindow() }
                .help("새 창에서 열기 (⌘O)")
                .disabled(model.detail == nil || model.multipleSelectionCount > 0)
        }
        .defaultCustomization(.hidden)
    }

    private func compose(_ kind: ComposeKind) {
        if let draft = model.draft(kind) { openWindow(id: "compose", value: draft) }
    }

    private func openInWindow() {
        switch model.openTarget() {
        case .compose(let draft): openWindow(id: "compose", value: draft)
        case .message(let id): openWindow(id: "message", value: id)
        case nil: break
        }
    }
}
