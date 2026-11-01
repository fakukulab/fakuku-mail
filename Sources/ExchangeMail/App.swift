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
            MailCommands(model: model, menu: menu.snapshot, threaded: $threaded)
        }

        WindowGroup("새로운 메시지", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft ?? ComposeDraft())
                .environment(model)
                .themed()
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 760, height: 680)
        .windowToolbarStyle(.unified)

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
    var isDraft = false
    var hasRemoteContent = false
}

final class MenuState: ObservableObject {
    static let shared = MenuState()
    @Published private(set) var snapshot = MenuSnapshot()

    func update(_ s: MenuSnapshot) {
        if snapshot != s { snapshot = s }
    }
}

struct MailCommands: Commands {
    let model: AppModel
    let menu: MenuSnapshot
    @Environment(\.openWindow) private var openWindow
    @Binding var threaded: Bool

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새로운 메시지") { openWindow(id: "compose", value: ComposeDraft()) }
                .keyboardShortcut("n")
                .disabled(!menu.signedIn)
        }
        CommandGroup(after: .sidebar) {
            // ⌥⌘T는 macOS의 "도구 막대 가리기"라 쓰지 않는다.
            Toggle("대화별로 정리", isOn: $threaded)
                .keyboardShortcut("t", modifiers: [.command, .control])
        }
        CommandGroup(replacing: .printItem) {
            Button("인쇄…") { model.printDisplayed() }
                .keyboardShortcut("p")
                .disabled(!menu.canPrint)
        }
        CommandMenu("사서함") {
            Button("새 폴더…") {
                if let name = TextPrompt.ask("새 폴더", confirm: "만들기") {
                    Task { await model.createFolder(named: name, parentID: nil) }
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .control])
            .disabled(!menu.signedIn)
        }
        CommandMenu("메시지") {
            Button("답장") { compose(.reply) }
                .keyboardShortcut("r")
                .disabled(!menu.hasMessage)
            Button("전체 답장") { compose(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!menu.hasMessage)
            Button("전달") { compose(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!menu.hasMessage)
            Button("첨부 훑어보기") { model.previewFirstAttachment() }
                .keyboardShortcut("y")
                .disabled(!menu.hasAttachments)
            Button("초안 이어서 쓰기") { if let d = model.resumeDraft() { openWindow(id: "compose", value: d) } }
                .keyboardShortcut("o")
                .disabled(!menu.isDraft)
            Divider()
            Button("보관") { Task { await model.archiveSelected(undoManager: NSApp.keyWindow?.undoManager) } }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(!menu.hasSelection)
            Button("이동…") { model.showMovePicker = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!menu.hasSelection)
            Button(menu.inJunk ? "정크 아님" : "정크 메일로 표시") {
                Task { await model.toggleJunkSelected(undoManager: NSApp.keyWindow?.undoManager) }
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!menu.hasSelection)
            // Delete 키는 목록의 onDeleteCommand가 맡는다 (메뉴 단축키로 쓰면 글자 입력 중에도 지워진다).
            Button("지우기") { Task { await model.deleteSelected(undoManager: NSApp.keyWindow?.undoManager) } }
                .disabled(!menu.hasSelection)
            Divider()
            Button(menu.isUnread ? "읽음으로 표시" : "읽지 않음으로 표시") { Task { await model.toggleReadSelected() } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!menu.hasSelection)
            Button(menu.isFlagged ? "깃발 떼기" : "깃발 달기") { Task { await model.toggleFlagSelected() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!menu.hasSelection)
            Divider()
            Button("원격 이미지 불러오기") { model.allowRemoteContentForSelection() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!menu.hasRemoteContent)
            Divider()
            Button("받은 메일 가져오기") { Task { await model.refresh() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!menu.signedIn)
        }
    }

    private func compose(_ kind: ComposeKind) {
        if let draft = model.draft(kind) { openWindow(id: "compose", value: draft) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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

/// Where local data lives: ~/Library/Application Support/ExchangeMail/
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

    static var directory: URL {
        let dir: URL
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            dir = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            dir = URL.applicationSupportDirectory.appending(path: "ExchangeMail", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
