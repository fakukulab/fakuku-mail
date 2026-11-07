import ExchangeMailKit
import SwiftUI

/// 메인 창의 도구 막대 (S-044). 보기 > 도구 막대 사용자화…로 넣고 뺀다.
/// 목록 열과 본문 열이 같은 id("mail")의 `.toolbar(id:)`를 따로 단다: 항목이 자기 열 위에 놓이고, 창에는 사용자화
/// 도구 막대 하나가 된다. 일반 `.toolbar {}` 항목이나 도구 막대의 검색 칸이 섞이면 사용자화가 꺼지거나 시트가 멈춘다.
extension MessageListView {
    @ToolbarContentBuilder
    var listToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "filter", placement: .primaryAction) { FilterMenu(model: model) }
        ToolbarItem(id: "sort", placement: .primaryAction) { SortMenu(model: model) }
        ToolbarItem(id: "listGetMail", placement: .primaryAction) {
            Button(L("받은 메일 가져오기"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help(L("받은 메일 가져오기 (⇧⌘N)"))
        }
        ToolbarItem(id: "listNewMessage", placement: .primaryAction) {
            Button(L("새로운 메시지"), systemImage: "square.and.pencil") { openWindow(id: "compose", value: ComposeDraft()) }
                .help(L("새로운 메시지 (⌘N)"))
        }
    }
}

extension MessageDetailView {
    @ToolbarContentBuilder
    var mailToolbar: some CustomizableToolbarContent {
        // 동작 단추는 본문 열 왼쪽 끝부터, 검색 칸은 오른쪽 끝에.
        organize
        ToolbarSpacer(.fixed)
        reply
        extras
        ToolbarSpacer(.flexible)
        ToolbarItem(id: "search") {
            MailSearchField(model: model)
        }
        // 검색 칸은 옮길 수만 있고 뺄 수는 없다.
        .customizationBehavior(.reorderable)
    }

    private var noSelection: Bool { model.selectedIDs.isEmpty }

    /// 고른 메일이 모두 깃발이면 채운 깃발
    private var allFlagged: Bool {
        let picked = model.messages.filter { model.selectedIDs.contains($0.id) }
        return !picked.isEmpty && picked.allSatisfy(\.isFlagged)
    }

    @ToolbarContentBuilder
    private var organize: some CustomizableToolbarContent {
        ToolbarItem(id: "archive") {
            Button(L("보관"), systemImage: "archivebox") { Task { await model.archiveSelected(undoManager: undoManager) } }
                .help(L("보관 (⌃⌘A)"))
                .disabled(noSelection)
        }
        ToolbarItem(id: "delete") {
            Button(L("지우기"), systemImage: "trash") { Task { await model.deleteSelected(undoManager: undoManager) } }
                .help(L("지우기 (Delete)"))
                .disabled(noSelection)
        }
        ToolbarItem(id: "junk") {
            Button(L("정크"), systemImage: "xmark.bin") { Task { await model.toggleJunkSelected(undoManager: undoManager) } }
                .help(L("정크 메일로 표시 / 정크 아님 (⇧⌘J)"))
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "move") {
            Button(L("이동"), systemImage: "folder") { model.showMovePicker = true }
                .help(L("다른 폴더로 이동 (⇧⌘M)"))
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "flag") {
            // 누르면 깃발 달기/떼기, ⌄로 색 고르기
            Menu {
                FlagColorItems { color in Task { await model.setFlagColorSelected(color) } }
            } label: {
                Label(L("깃발"), systemImage: allFlagged ? "flag.fill" : "flag")
            } primaryAction: {
                Task { await model.toggleFlagSelected() }
            }
            .help(L("깃발 달기/떼기 (⇧⌘L), 색은 ⌄ (⌥⌘1~7)"))
            .disabled(noSelection)
        }
    }

    @ToolbarContentBuilder
    private var reply: some CustomizableToolbarContent {
        ToolbarItem(id: "reply") {
            Button(L("답장"), systemImage: "arrowshape.turn.up.left") { compose(.reply) }
                .help(L("답장 (⌘R)"))
                .disabled(model.detail == nil)
        }
        ToolbarItem(id: "replyAll") {
            Button(L("전체 답장"), systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll) }
                .help(L("전체 답장 (⇧⌘R)"))
                .disabled(model.detail == nil)
        }
        ToolbarItem(id: "forward") {
            Button(L("전달"), systemImage: "arrowshape.turn.up.right") { compose(.forward) }
                .help(L("전달 (⇧⌘F)"))
                .disabled(model.detail == nil)
        }
    }

    /// 처음에는 숨겨 두고 사용자화 시트에서 끌어 넣는 항목
    @ToolbarContentBuilder
    private var extras: some CustomizableToolbarContent {
        ToolbarItem(id: "read") {
            // 맥 Mail처럼 할 일 하나만 보인다 (1.0.2)
            let unread = model.selectionHasUnread
            Button(unread ? L("읽음으로 표시") : L("읽지 않음으로 표시"),
                   systemImage: unread ? "envelope.open" : "envelope.badge") { Task { await model.toggleReadSelected() } }
                .help(unread ? L("읽음으로 표시 (⇧⌘U)") : L("읽지 않음으로 표시 (⇧⌘U)"))
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "print") {
            Button(L("인쇄"), systemImage: "printer") { model.printDisplayed() }
                .help(L("인쇄 (⌘P)"))
                .disabled(model.detail == nil || model.multipleSelectionCount > 0)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "openWindow") {
            Button(L("새 창에서 열기"), systemImage: "macwindow.on.rectangle") { openInWindow() }
                .help(L("새 창에서 열기 (⌘O)"))
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
