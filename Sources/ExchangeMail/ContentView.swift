import AppKit
import ExchangeMailKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// 설정 > 일반 > 새 메일 확인 (분, 0이면 수동)
    @AppStorage("refresh.minutes") private var refreshMinutes = 2

    var body: some View {
        @Bindable var model = model
        Group {
            if model.showsMail {
                MailSplitView()
            } else {
                SignInView()
            }
        }
        .task {
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings, openWindow: openWindow)
        }
        .task(id: model.isSignedIn) { await model.reloadAll() }
        .task(id: "\(model.isSignedIn)-\(refreshMinutes)") { await autoRefresh() }
        .task(id: model.isSignedIn) {
            NotificationRouter.shared.open = { id in Task { await model.openFromNotification(id) } }
            await model.prepareNotifications()
        }
        .alert("오류", isPresented: Binding(get: { model.errorMessage != nil },
                                          set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// 설정한 간격마다(기본 2분): 앱이 앞에 있으면 화면을 새로 고치고(S-015), 뒤에 있어도 새 메일을 확인해 알린다(S-024).
    /// 수동이면 받은 메일 가져오기(⇧⌘N)를 누를 때만.
    private func autoRefresh() async {
        guard model.isSignedIn, !model.isDemo else { return }
        await model.checkNewMail()   // 처음 한 번: 새 메일 기준을 정한다
        guard refreshMinutes > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double(refreshMinutes) * 60))
            if Task.isCancelled { break }
            if NSApp.isActive { await model.refresh() }
            await model.checkNewMail()
        }
    }
}

struct MailSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            FolderSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        } detail: {
            MessageDetailView()
        }
        // 검색 칸은 사이드바 위에 둔다. 도구 막대에 두면 사용자화 시트가 검색 칸을 그리다 AppKit 예외로
        // 앱이 꺼진다 (macOS 27, NSSearchToolbarItemView 제약 오류).
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "검색")
        // 검색 범위: 이 폴더 / 모든 폴더 (S-033)
        .searchScopes($model.searchScope) {
            Text("이 폴더").tag(SearchScope.folder)
            Text("모든 폴더").tag(SearchScope.all)
        }
        .onSubmit(of: .search) { Task { await model.loadMessages() } }
        // 메시지 > 이동… (S-028)
        .sheet(isPresented: $model.showMovePicker) { MovePicker() }
        // VIP 지정·변경 (S-045), 스마트 메일상자 (S-046)
        .sheet(item: $model.editingVIP) { vip in
            VIPEditor(vip: vip, isNew: model.mailboxes.vip(address: vip.address) == nil)
        }
        .sheet(item: $model.editingSmart) { box in
            SmartMailboxEditor(box: box, isNew: !model.mailboxes.smart.contains { $0.id == box.id })
        }
        .onChange(of: model.searchText) { old, new in
            // 검색어를 지우면 원래 목록으로 돌아간다 (S-014).
            if new.isEmpty && !old.isEmpty { Task { await model.loadMessages() } }
        }
    }
}

struct FolderSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedFolderID) {
            Section("스마트 메일상자") {
                Label("깃발 표시", systemImage: "flag")
                    .tag(FolderOrder.flaggedID)
                // 사람이 만든 상자 (S-046)
                ForEach(model.mailboxes.smart) { box in
                    Label(box.name, systemImage: box.symbol)
                        .tag(box.id)
                        .help(box.summary { id in model.folders.first { $0.id == id }?.displayName })
                        .contextMenu {
                            Button("스마트 메일상자 변경…") { model.editingSmart = box }
                            Button("스마트 메일상자 지우기…", role: .destructive) {
                                if TextPrompt.confirm("\"\(box.name)\" 스마트 메일상자를 지울까요?",
                                                      message: "메일은 지워지지 않고 원래 폴더에 남습니다.", action: "지우기") {
                                    model.removeSmart(id: box.id)
                                }
                            }
                        }
                }
            }
            // VIP (S-045): 사람마다 이름과 아이콘
            if !model.mailboxes.vips.isEmpty {
                Section("VIP") {
                    Label("모든 VIP", systemImage: "star")
                        .tag(VirtualMailbox.allVIPsID)
                    ForEach(model.mailboxes.vips) { vip in
                        Label(vip.title, systemImage: vip.symbol)
                            .tag(VirtualMailbox.id(forVIP: vip.address))
                            .help(vip.address)
                            .contextMenu {
                                Button("이름·아이콘 변경…") { model.editingVIP = vip }
                                Button("VIP에서 빼기") { model.removeVIP(address: vip.address) }
                            }
                    }
                }
            }
            Section(model.auth.email ?? "사서함") {
                ForEach(model.folders) { folder in
                    FolderRow(folder: folder)
                        .tag(folder.id)
                        // 메일 줄을 끌어다 놓으면 이 폴더로 옮긴다 (S-028).
                        .dropDestination(for: String.self) { payloads, _ in
                            Task { await model.dropped(payloads, onto: folder.id, undoManager: undoManager) }
                            return folder.id != model.selectedFolderID
                        }
                        .contextMenu { folderMenu(folder) }
                }
            }
        }
        .contextMenu {
            Button("새 폴더…") { newFolder(parent: nil) }
            Button("새 스마트 메일상자…") { model.newSmartMailbox() }
        }
        .overlay {
            if model.folders.isEmpty && model.isLoading {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: MailFolder) -> some View {
        Button("새 하위 폴더…") { newFolder(parent: folder) }
        Divider()
        Button("이름 변경…") {
            if let name = TextPrompt.ask("폴더 이름 변경", initial: folder.displayName, confirm: "변경") {
                Task { await model.renameFolder(folder, to: name) }
            }
        }
        .disabled(!folder.isEditable)
        Button("폴더 지우기…", role: .destructive) {
            if TextPrompt.confirm("\"\(folder.displayName)\" 폴더를 지울까요?",
                                  message: "폴더와 안의 메일, 하위 폴더가 지운 편지함으로 옮겨집니다.", action: "지우기") {
                Task { await model.deleteFolder(folder) }
            }
        }
        .disabled(!folder.isEditable)
    }

    private func newFolder(parent: MailFolder?) {
        let message = parent.map { "\"\($0.displayName)\" 안에 만듭니다." } ?? ""
        if let name = TextPrompt.ask("새 폴더", message: message, confirm: "만들기") {
            Task { await model.createFolder(named: name, parentID: parent?.id) }
        }
    }
}

/// 폴더 한 줄: 하위 폴더는 깊이만큼 들여 쓴다 (S-031).
struct FolderRow: View {
    let folder: MailFolder

    var body: some View {
        Label(folder.displayName, systemImage: folder.symbol)
            .padding(.leading, CGFloat(folder.depth ?? 0) * Space.lg)
            .badge(folder.unreadItemCount ?? 0)
    }
}
