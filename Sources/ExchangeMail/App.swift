import AppKit
import ExchangeMailKit
import SwiftUI
import UserNotifications

// FAKUKU Mail (code name ExchangeMail)
//   ExchangeMail                       the app (Microsoft Graph, real account)
//   APP_STORE=<dir> ExchangeMail       keep signatures in another folder (tests, experiments)
//   APP_SEED=1 ExchangeMail            demo mode: sample folders and mail, no sign-in (needs APP_STORE in /tmp)
//   APP_SNAPSHOT=<dir> ExchangeMail    save a PNG of every folder page, the sign-in page, a compose window,
//                                      and every Settings tab in light and dark mode, then quit (tools/snap.sh)
//   ExchangeMail --selftest            run the self-test in demo mode on a /tmp store, quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> ExchangeMail       run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 ExchangeMail            draw the 8 pt grid and the layout probes over the window

@main
struct ExchangeMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.make()
    /// SwiftUI Commands do not observe @Observable models. MenuState mirrors what the menus need.
    @ObservedObject private var menu = MenuState.shared
    /// 보기 > 대화별로 정리. App이 들고 있어야 바꿀 때 메뉴(체크 표시)가 다시 그려진다.
    @AppStorage("list.threaded") private var threaded = true
    /// 작성 창 머리글 필드 (보기 메뉴의 체크 표시가 바뀌도록 App이 들고 있다)
    @AppStorage(Prefs.fieldCc) private var fieldCc = true
    @AppStorage(Prefs.fieldBcc) private var fieldBcc = false
    @AppStorage(Prefs.fieldReplyTo) private var fieldReplyTo = false
    @AppStorage(Prefs.fieldPriority) private var fieldPriority = true

    var body: some Scene {
        Window("FAKUKU Mail", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 960, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            MailCommands(model: model, menu: menu.snapshot, threaded: $threaded,
                         fieldCc: $fieldCc, fieldBcc: $fieldBcc, fieldReplyTo: $fieldReplyTo, fieldPriority: $fieldPriority)
        }

        WindowGroup(L("새로운 메시지"), id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft ?? ComposeDraft())
                .environment(model)
                .themed()
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 760, height: 680)
        .windowToolbarStyle(.unified)

        // 메일을 별도 창으로 (S-043). 같은 메일을 다시 열면 그 창을 앞으로 가져온다.
        WindowGroup(L("메시지"), id: "message", for: String.self) { $id in
            MessageWindow(messageID: id ?? "")
                .environment(model)
                .themed()
                .frame(minWidth: 520, minHeight: 420)
        }
        .defaultSize(width: 820, height: 760)
        .windowToolbarStyle(.unified)

        // 개별 발송 (M18)
        Window(L("개별 발송"), id: "merge") {
            MergeWindow()
                .environment(model)
                .themed()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1040, height: 720)

        // 원본 보기 (M17)
        WindowGroup(L("원본"), id: "source", for: String.self) { $id in
            SourceWindow(messageID: id ?? "")
                .environment(model)
                .themed()
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 760, height: 640)

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

/// What the menu bar needs to know, copied out of the model.
struct MenuSnapshot: Equatable {
    var signedIn = false
    var hasMessage = false
    /// 한 통 이상 골랐다 (여러 통 포함, S-027)
    var hasSelection = false
    var isUnread = false
    var isFlagged = false
    var inJunk = false
    var hasAttachments = false
    /// 본문이 보이면 인쇄할 수 있다 (대화 안의 다른 메일을 펼쳤을 때도)
    var canPrint = false
    var sortKey = MailSort.Key.date
    var sortDescending = true
    var filter = MailFilter()
    var isDraft = false
    var hasRemoteContent = false
    /// 본문의 보낸 사람이 VIP (S-045)
    var senderIsVIP = false
    // M17
    /// 'X'(으)로 다시 이동할 폴더 이름
    var lastMoveTitle: String?
    /// 고른 대화의 알림이 꺼져 있다
    var isMuted = false
    /// 본문 메일의 우선 순위 (low, normal, high)
    var importance: String?
    /// 고른 사이드바 항목이 서버 폴더다 (모두 읽음)
    var inServerFolder = false
    /// 고른 사이드바 항목이 이름을 바꾸거나 지울 수 있는 폴더다
    var folderEditable = false
    /// 고른 사이드바 항목이 스마트 메일상자다
    var smartSelected = false
    /// 다음으로 이동·복사 하위 메뉴
    var moveTargets: [MoveTarget] = []
    /// 메일상자 내보내기 중 (S-053)
    var exporting = false
    /// 사이드바에서 나의 Mac에 상자를 골랐다 (S-055)
    var localSelected = false

    var filterActive: Bool { filter.isActive }
}

final class MenuState: ObservableObject {
    static let shared = MenuState()
    @Published private(set) var snapshot = MenuSnapshot()

    func update(_ s: MenuSnapshot) {
        if snapshot != s { snapshot = s }
    }
}

/// 메뉴 막대 (맥 Mail의 메뉴 구성을 따른다, M17).
struct MailCommands: Commands {
    let model: AppModel
    let menu: MenuSnapshot
    @Environment(\.openWindow) private var openWindow
    /// 앞에 있는 메시지 창 (S-043). 있으면 메시지 메뉴가 그 창의 메일에 동작한다.
    @FocusedValue(\.messageReader) private var reader
    /// 앞에 있는 작성 창의 편집기. 포맷 메뉴가 쓴다.
    @FocusedValue(\.richTextEditor) private var editor
    @Binding var threaded: Bool
    @Binding var fieldCc: Bool
    @Binding var fieldBcc: Bool
    @Binding var fieldReplyTo: Bool
    @Binding var fieldPriority: Bool

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("새로운 메시지")) { openWindow(id: "compose", value: ComposeDraft()) }
                .keyboardShortcut("n")
                .disabled(!menu.signedIn)
        }
        // S-053: 내 Mac에 보관한 메일(.mbox, .eml)을 연다. 맥 Mail처럼 파일 메뉴에 따로 둔다. 로그인하지 않아도 된다.
        CommandGroup(after: .newItem) {
            Divider()
            Button(L("메일상자 가져오기…")) { model.importLocalMailbox() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(after: .sidebar) { viewMenu }
        CommandGroup(replacing: .printItem) {
            Button(L("인쇄…")) {
                if let reader { reader.print(model: model) } else { model.printDisplayed() }
            }
            .keyboardShortcut("p")
            .disabled(reader == nil && !menu.canPrint)
        }
        CommandMenu(L("메일상자")) { mailboxMenu }
        CommandMenu(L("메시지")) { messageMenu }
        CommandMenu(L("포맷")) { formatMenu }
        CommandGroup(before: .windowList) {
            Button(L("메시지 뷰어")) { openWindow(id: "main") }
                .keyboardShortcut("0")
            Divider()
        }
    }

    // MARK: 보기

    @ViewBuilder
    private var viewMenu: some View {
        // ⌥⌘T는 macOS의 "도구 막대 가리기"라 쓰지 않는다.
        Toggle(L("대화별로 정리"), isOn: $threaded)
            .keyboardShortcut("t", modifiers: [.command, .control])
        // 본문 위 대화 목록 높이 (경계선을 끌어도 된다)
        Menu(L("대화 목록 높이")) {
            Button(L("늘리기")) { Prefs.adjustThreadHeight(by: Prefs.threadHeightStep) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button(L("줄이기")) { Prefs.adjustThreadHeight(by: -Prefs.threadHeightStep) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(L("기본 높이")) { Prefs.adjustThreadHeight(by: 0) }
        }
        .disabled(!threaded)
        // 필터 (S-041)
        Menu(L("필터")) {
            filterToggle(L("읽지 않음"), \.unread)
            filterToggle(L("깃발 표시됨"), \.flagged)
            filterToggle(L("첨부 파일 있음"), \.hasAttachments)
            filterToggle(L("높은 우선순위"), \.highImportance)
            filterToggle(L("받는 사람·참조에 나"), \.toOrCcMe)
            filterToggle(L("멘션(@)"), \.mentionsMe)
            Divider()
            Button(L("모든 필터 해제")) { model.listFilter = MailFilter() }
                .disabled(!menu.filterActive)
        }
        // 정렬 기준 (S-042)
        Menu(L("정렬 기준")) {
            ForEach(MailSort.Key.allCases, id: \.self) { key in
                Button {
                    model.listSort.key = key
                } label: {
                    if menu.sortKey == key { Label(key.label, systemImage: "checkmark") } else { Text(key.label) }
                }
            }
            Divider()
            Button(menu.sortKey == .date ? L("새로운 항목 우선") : L("내림차순")) { model.listSort.descending = true }
                .disabled(menu.sortDescending)
            Button(menu.sortKey == .date ? L("오래된 항목 우선") : L("오름차순")) { model.listSort.descending = false }
                .disabled(!menu.sortDescending)
        }
        Button(L("모든 필터 해제")) { model.listFilter = MailFilter() }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!menu.filterActive)
        Divider()
        // 작성 창 머리글 필드 (맥 Mail 보기 메뉴와 같은 자리·단축키)
        Toggle(L("참조 주소 필드"), isOn: $fieldCc)
        Toggle(L("숨은 참조 주소 필드"), isOn: $fieldBcc)
            .keyboardShortcut("b", modifiers: [.command, .option])
        Toggle(L("답장 받을 사람 주소 필드"), isOn: $fieldReplyTo)
            .keyboardShortcut("r", modifiers: [.command, .option])
        Toggle(L("우선 순위 필드"), isOn: $fieldPriority)
        Divider()
        // 원본 보기: 모든 헤더와 본문 (M17)
        Button(L("원본 보기")) {
            if let id = reader?.messageID ?? model.detail?.id { openWindow(id: "source", value: id) }
        }
        .keyboardShortcut("u", modifiers: [.command, .option])
        .disabled(!hasMessage)
        Divider()
    }

    private func filterToggle(_ title: String, _ key: WritableKeyPath<MailFilter, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { menu.filter[keyPath: key] }, set: { model.listFilter[keyPath: key] = $0 }))
            .disabled(!menu.signedIn)
    }

    // MARK: 메일상자

    @ViewBuilder
    private var mailboxMenu: some View {
        Button(L("모든 새로운 메일 가져오기")) { Task { await model.refresh() } }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!menu.signedIn)
        Button(L("모든 메시지를 읽음으로 표시")) { Task { await model.markAllReadInFolder() } }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(!menu.inServerFolder)
        Divider()
        Button(L("지운 편지함 비우기…")) {
            if TextPrompt.confirm(L("지운 편지함을 비울까요?"),
                                  message: L("지운 편지함의 메일 \(model.folderCount(kind: "deleteditems"))통을 영구히 지웁니다. 되돌릴 수 없습니다."),
                                  action: L("비우기")) {
                Task { await model.emptyFolder(kind: "deleteditems") }
            }
        }
        .keyboardShortcut(.delete, modifiers: [.command, .shift, .option])
        .disabled(!menu.signedIn)
        Button(L("정크 메일 지우기…")) {
            if TextPrompt.confirm(L("정크 메일을 지울까요?"),
                                  message: L("정크 메일 폴더의 메일 \(model.folderCount(kind: "junkemail"))통을 지운 편지함으로 옮깁니다."),
                                  action: L("지우기")) {
                Task { await model.emptyFolder(kind: "junkemail") }
            }
        }
        .keyboardShortcut("j", modifiers: [.command, .option])
        .disabled(!menu.signedIn)
        Divider()
        Button(L("새 폴더…")) {
            if let name = TextPrompt.ask(L("새 폴더"), confirm: L("만들기")) {
                Task { await model.createFolder(named: name, parentID: nil) }
            }
        }
        .keyboardShortcut("n", modifiers: [.command, .control])
        .disabled(!menu.signedIn)
        Button(L("폴더 이름 변경…")) {
            if let box = model.selectedLocalBox {
                model.renameLocal(box)
            } else if let folder = model.selectedEditableFolder,
               let name = TextPrompt.ask(L("폴더 이름 변경"), initial: folder.displayName, confirm: L("변경")) {
                Task { await model.renameFolder(folder, to: name) }
            }
        }
        .disabled(!menu.folderEditable)
        Button(L("폴더 지우기…")) {
            if let box = model.selectedLocalBox {
                model.removeLocal(box)
            } else if let folder = model.selectedEditableFolder,
               TextPrompt.confirm(L("\"\(folder.displayName)\" 폴더를 지울까요?"),
                                  message: L("폴더와 안의 메일, 하위 폴더가 지운 편지함으로 옮겨집니다."), action: L("지우기")) {
                Task { await model.deleteFolder(folder) }
            }
        }
        .disabled(!menu.folderEditable)
        Divider()
        // S-053: 고른 폴더를 내 Mac의 .mbox 파일로
        if menu.exporting {
            Button(L("내보내기 중단")) { model.cancelExport() }
                .keyboardShortcut("e", modifiers: [.command, .option])
        } else {
            Button(L("메일상자 내보내기…")) { model.exportSelectedMailbox() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!menu.inServerFolder && !menu.localSelected)
        }
        Button(L("메일상자 가져오기…")) { model.importLocalMailbox() }
        Divider()
        Button(L("새 스마트 메일상자…")) { model.newSmartMailbox() }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!menu.signedIn)
        Button(L("스마트 메일상자 편집…")) {
            if let id = model.selectedFolderID { model.editingSmart = model.mailboxes.smart.first { $0.id == id } }
        }
        .disabled(!menu.smartSelected)
        Button(L("스마트 메일상자 복제")) { if let id = model.selectedFolderID { model.duplicateSmart(id: id) } }
            .disabled(!menu.smartSelected)
        Divider()
        Button(L("메일 검색")) {
            // AppKit으로 칸을 찾아 초점을 주고, 못 찾으면 SwiftUI 쪽 요청으로 한 번 더.
            if !SearchFieldFocus.focus() { model.searchFocusRequest += 1 }
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .disabled(!menu.signedIn)
        Divider()
        Button(L("이전 메일상자로 이동")) { model.selectAdjacentMailbox(-1) }
            .keyboardShortcut("[", modifiers: [.command, .control])
            .disabled(!menu.signedIn)
        Button(L("다음 메일상자로 이동")) { model.selectAdjacentMailbox(1) }
            .keyboardShortcut("]", modifiers: [.command, .control])
            .disabled(!menu.signedIn)
    }

    // MARK: 메시지

    @ViewBuilder
    private var messageMenu: some View {
        Button(L("개별 발송…")) { openWindow(id: "merge") }
            .keyboardShortcut("m", modifiers: [.command, .option, .shift])
            .disabled(!menu.signedIn)
        Button(L("다시 보내기")) { if let d = model.sendAgainDraft() { openWindow(id: "compose", value: d) } }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(reader != nil || !menu.hasMessage)
        Divider()
        Button(L("답장")) { compose(.reply) }
            .keyboardShortcut("r")
            .disabled(!hasMessage)
        Button(L("전체 답장")) { compose(.replyAll) }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasMessage)
        Button(L("전달")) { compose(.forward) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!hasMessage)
        Button(L("첨부 파일로 전달")) { if let d = model.forwardAsAttachmentDraft() { openWindow(id: "compose", value: d) } }
            .keyboardShortcut("f", modifiers: [.command, .shift, .option])
            .disabled(reader != nil || !menu.hasMessage)
        Button(L("첨부 훑어보기")) {
            if let reader { reader.previewFirstAttachment(model: model) } else { model.previewFirstAttachment() }
        }
        .keyboardShortcut("y")
        .disabled(reader == nil && !menu.hasAttachments)
        // 임시 보관함의 초안은 작성 창에서, 그 밖의 메일은 메시지 창에서 연다 (S-022, S-043).
        Button(menu.isDraft ? L("초안 이어서 쓰기") : L("새 창에서 열기")) { openSelected() }
            .keyboardShortcut("o")
            .disabled(reader != nil || !menu.hasMessage)
        Divider()
        // 이동, 정크, 읽음, 우선 순위, 알림은 목록의 선택에 한다. 메시지 창이 앞에 있으면 끈다.
        Button(menu.isUnread ? L("읽음으로 표시") : L("읽지 않음으로 표시")) { Task { await model.toggleReadSelected() } }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(reader != nil || !menu.hasSelection)
        Button(menu.inJunk ? L("정크 아님") : L("정크 메일로 표시")) {
            Task { await model.toggleJunkSelected(undoManager: NSApp.keyWindow?.undoManager) }
        }
        .keyboardShortcut("j", modifiers: [.command, .shift])
        .disabled(reader != nil || !menu.hasSelection)
        Button(menu.isMuted ? L("알림 활성화") : L("알림 비활성화")) { model.toggleMuteSelected() }
            .keyboardShortcut("m", modifiers: [.control, .shift])
            .disabled(reader != nil || !menu.hasSelection)
        Button(flagLabel) {
            if let reader {
                Task { await reader.toggleFlag(model: model) }
            } else {
                Task { await model.toggleFlagSelected() }
            }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(reader == nil && !menu.hasSelection)
        // 깃발 색 (맥 Mail처럼 ⌥⌘1~7). Exchange에는 색이 없어 이 Mac에 저장한다.
        Menu(L("깃발 색")) {
            FlagColorItems(shortcuts: true) { color in
                if let reader {
                    Task { await reader.setFlagColor(color, model: model) }
                } else {
                    Task { await model.setFlagColorSelected(color) }
                }
            }
        }
        .disabled(reader == nil && !menu.hasSelection)
        Menu(L("우선 순위 설정")) {
            ForEach([("high", L("높음")), ("normal", L("보통")), ("low", L("낮음"))], id: \.0) { pair in
                Button {
                    Task { await model.setImportanceSelected(pair.0) }
                } label: {
                    if (menu.importance ?? "normal") == pair.0 { Label(pair.1, systemImage: "checkmark") } else { Text(pair.1) }
                }
            }
        }
        .disabled(reader != nil || !menu.hasSelection)
        Divider()
        Button(L("보관")) {
            if let reader {
                Task { await reader.move(to: "archive", undoName: L("보관"), model: model) }
            } else {
                Task { await model.archiveSelected(undoManager: NSApp.keyWindow?.undoManager) }
            }
        }
        .keyboardShortcut("a", modifiers: [.command, .control])
        .disabled(reader == nil && !menu.hasSelection)
        Button(menu.lastMoveTitle.map { L("'\($0)'(으)로 다시 이동") } ?? L("같은 폴더로 다시 이동")) {
            Task { await model.moveSelectedToLastTarget(undoManager: NSApp.keyWindow?.undoManager) }
        }
        .keyboardShortcut("m", modifiers: [.command, .control])
        .disabled(reader != nil || !menu.hasSelection || menu.lastMoveTitle == nil)
        Menu(L("다음으로 이동")) {
            ForEach(menu.moveTargets) { target in
                Button(target.title) {
                    Task {
                        await model.moveSelected(to: target.id, undoManager: NSApp.keyWindow?.undoManager, undoName: L("이동"))
                    }
                }
            }
        }
        .disabled(reader != nil || !menu.hasSelection)
        Menu(L("다음으로 복사")) {
            ForEach(menu.moveTargets) { target in
                Button(target.title) { Task { await model.copySelected(to: target.id) } }
            }
        }
        .disabled(reader != nil || !menu.hasSelection)
        Button(L("이동…")) { model.showMovePicker = true }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(reader != nil || !menu.hasSelection)
        // Delete 키는 목록과 메시지 창의 onDeleteCommand가 맡는다 (메뉴 단축키로 쓰면 글자 입력 중에도 지워진다).
        Button(L("지우기")) {
            if let reader {
                Task { await reader.move(to: "deleteditems", undoName: L("지우기"), model: model) }
            } else {
                Task { await model.deleteSelected(undoManager: NSApp.keyWindow?.undoManager) }
            }
        }
        .disabled(reader == nil && !menu.hasSelection)
        Divider()
        // VIP (S-045)
        Button(vipTargetIsVIP ? L("VIP에서 빼기") : L("보낸 사람을 VIP로 지정…")) {
            guard let m = vipTarget, let address = m.from?.emailAddress.address else { return }
            if vipTargetIsVIP { model.removeVIP(address: address) } else { model.editVIP(for: m) }
        }
        .keyboardShortcut("v", modifiers: [.command, .control])
        .disabled(!hasMessage)
        Button(L("VIP 이름·아이콘 변경…")) { if let m = vipTarget { model.editVIP(for: m) } }
            .disabled(!vipTargetIsVIP)
        // 설정 > 정크 메일 > 차단됨 (받은 편지함 서버 규칙)
        Button(L("보낸 사람 차단")) {
            if let m = vipTarget { Task { await model.blockSender(of: m, undoManager: NSApp.keyWindow?.undoManager) } }
        }
        .keyboardShortcut("b", modifiers: [.command, .control])
        .disabled(!hasMessage)
        Divider()
        Button(L("원격 이미지 불러오기")) {
            if let reader { reader.allowRemoteContent() } else { model.allowRemoteContentForSelection() }
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(reader == nil && !menu.hasRemoteContent)
    }

    // MARK: 포맷 (작성 창)

    @ViewBuilder
    private var formatMenu: some View {
        Button(L("Siri로 글쓰기")) { editor?.showWritingTools() }
            .keyboardShortcut("w", modifiers: [.command, .control])
            .disabled(editor == nil)
        Divider()
        Menu(L("스타일")) {
            Button(L("굵게")) { editor?.command("bold") }
                .keyboardShortcut("b")
            Button(L("기울임꼴")) { editor?.command("italic") }
                .keyboardShortcut("i")
            Button(L("밑줄")) { editor?.command("underline") }
                .keyboardShortcut("u")
            Button(L("취소선")) { editor?.command("strikeThrough") }
                .keyboardShortcut("x", modifiers: [.command, .control])
        }
        .disabled(editor == nil)
        Menu(L("목록")) {
            Button(L("글머리 기호 목록")) { editor?.command("insertUnorderedList") }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button(L("번호 목록")) { editor?.command("insertOrderedList") }
                .keyboardShortcut("8", modifiers: [.command, .shift])
        }
        .disabled(editor == nil)
        Menu(L("정렬")) {
            Button(L("왼쪽 정렬")) { editor?.command("justifyLeft") }
                .keyboardShortcut("{")
            Button(L("가운데 정렬")) { editor?.command("justifyCenter") }
                .keyboardShortcut("|")
            Button(L("오른쪽 정렬")) { editor?.command("justifyRight") }
                .keyboardShortcut("}")
        }
        .disabled(editor == nil)
        Divider()
        Menu(L("들여쓰기")) {
            Button(L("들여쓰기")) { editor?.indent() }
                .keyboardShortcut("]")
            Button(L("내어쓰기")) { editor?.outdent() }
                .keyboardShortcut("[")
        }
        .disabled(editor == nil)
        Menu(L("인용 단계")) {
            Button(L("인용 단계 늘리기")) { editor?.quoteMore() }
                .keyboardShortcut("'")
            Button(L("인용 단계 줄이기")) { editor?.quoteLess() }
                .keyboardShortcut("'", modifiers: [.command, .option])
        }
        .disabled(editor == nil)
    }

    // MARK: helpers

    /// 답장·전달할 메일이 있다: 앞의 메시지 창, 또는 메인 창의 본문
    private var hasMessage: Bool { reader != nil || menu.hasMessage }

    /// VIP 메뉴가 다룰 메일: 앞의 메시지 창, 또는 메인 창의 본문
    private var vipTarget: MailMessage? { reader?.message ?? model.detail }
    private var vipTargetIsVIP: Bool {
        if let m = reader?.message { return model.mailboxes.vip(for: m) != nil }
        return menu.senderIsVIP
    }

    private var flagLabel: String {
        if let reader { return reader.message?.isFlagged == true ? L("깃발 떼기") : L("깃발 달기") }
        return menu.isFlagged ? L("깃발 떼기") : L("깃발 달기")
    }

    private func compose(_ kind: ComposeKind) {
        let draft = reader.map { $0.draft(kind, model: model) } ?? model.draft(kind)
        if let draft { openWindow(id: "compose", value: draft) }
    }

    private func openSelected() {
        switch model.openTarget() {
        case .compose(let draft): openWindow(id: "compose", value: draft)
        case .message(let id): openWindow(id: "message", value: id)
        case nil: break
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // 설정 > 일반 > 앱 아이콘 색 (Dock 아이콘)
        if !Store.isOverridden { AppIconColor.apply() }
        // 알림을 눌러 앱이 켜진 경우도 받도록 시작하자마자 연결한다 (S-024). 테스트 실행은 건드리지 않는다.
        if !Store.isOverridden {
            UNUserNotificationCenter.current().delegate = SystemNotifier.shared
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Where local data lives: ~/Library/Application Support/FAKUKUMail/ (before: …/ExchangeMail/, moved on first launch)
/// Mail stays on the server; only signatures are stored here. Tokens are in the Keychain.
enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, demo mode).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    /// Demo mode: sample mail and no sign-in. Only with a /tmp store, so it never mixes with real data.
    static var isDemo: Bool {
        isOverridden && (ProcessInfo.processInfo.environment["APP_SEED"] == "1" || SelfTest.requested)
    }

    /// ~/Library/Application Support/FAKUKUMail. 예전 이름(ExchangeMail) 폴더가 있으면 처음 한 번 그대로 옮긴다:
    /// 서명, VIP·스마트 메일상자, 개별 발송, 오프라인 캐시, 나의 Mac에 상자가 그대로 남는다.
    static let appSupport: URL = migrated(in: URL.applicationSupportDirectory)

    /// `base` 안의 데이터 폴더. 셀프 테스트는 /tmp를 넣어 옮기기를 확인한다.
    static func migrated(in base: URL) -> URL {
        let fm = FileManager.default
        let new = base.appending(path: "FAKUKUMail", directoryHint: .isDirectory)
        let old = base.appending(path: "ExchangeMail", directoryHint: .isDirectory)
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            // 옮기지 못하면(권한 등) 예전 폴더를 계속 쓴다: 데이터를 잃지 않게.
            if (try? fm.moveItem(at: old, to: new)) == nil { return old }
        }
        return new
    }

    static var directory: URL {
        let dir: URL
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            dir = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            dir = appSupport
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
