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
        // Siri·단축어 (Intents/MailIntents.swift)
        .onAppear { IntentModel.current = model }
        .onChange(of: model.pendingCompose) { _, draft in
            if let draft {
                openWindow(id: "compose", value: draft)
                model.pendingCompose = nil
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
        .alert(L("알림"), isPresented: Binding(get: { model.noticeMessage != nil },
                                          set: { if !$0 { model.noticeMessage = nil } })) {
            Button(L("확인"), role: .cancel) {}
        } message: {
            Text(model.noticeMessage ?? "")
        }
        .alert(L("오류"), isPresented: Binding(get: { model.errorMessage != nil },
                                          set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("확인"), role: .cancel) {}
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
            // 나의 Mac에 상자를 고르면 이 Mac의 파일에서 읽은 목록과 본문을 위에 덮는다 (S-055).
            // 열의 뷰를 통째로 바꾸면 그 열의 사용자화 도구 막대(.toolbar(id:))가 빠졌다 들어가며
            // AppKit이 도구 막대를 다시 짜다 앱이 꺼진다(NSToolbarItemViewer). 그래서 열 뷰는 그대로 두고 덮는다.
            MessageListView()
                .overlay {
                    if model.selectedLocalBox != nil {
                        LocalMailList()
                            .background(.background)
                    }
                }
                .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        } detail: {
            MessageDetailView()
                .overlay {
                    if model.selectedLocalBox != nil {
                        LocalMailDetail()
                            .background(.background)
                    }
                }
        }
        // 검색 칸은 본문 열 도구 막대 오른쪽의 MailSearchField (Views/MailSearchField.swift).
        // 시스템 .searchable은 쓰지 않는다: 도구 막대에 두면 사용자화 시트가 그 칸을 그리다 앱이 꺼지고(macOS 27),
        // 사이드바에 두면 검색 범위가 두 번 보인다.
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
    /// 접어 둔 구역 (줄마다 하나: "smart", "vip", "local", "account.<id>"). 맥 Mail처럼 구역 이름에 마우스를 올리면 ⌄·›가 보인다.
    @AppStorage("sidebar.collapsed") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) },
                set: { open in
                    var set = collapsed
                    if open { set.remove(key) } else { set.insert(key) }
                    collapsedRaw = set.sorted().joined(separator: "\n")
                })
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedFolderID) {
            Section {
                if expanded("smart").wrappedValue {
                // 계정이 둘 이상이면 모든 계정의 받은 편지함을 한곳에 (M23)
                if model.showsAllInboxes {
                    Label(L("모든 받은 편지함"), systemImage: "tray.2")
                        .tag(VirtualMailbox.allInboxesID)
                }
                Label(L("깃발 표시"), systemImage: "flag")
                    .tag(FolderOrder.flaggedID)
                // 색별 깃발 (쓰는 색만)
                ForEach(model.usedFlagColors, id: \.self) { c in
                    Label {
                        Text(c.label)
                    } icon: {
                        c.flagImage
                    }
                    .padding(.leading, Space.lg)
                    .tag(VirtualMailbox.id(for: c))
                }
                // 사람이 만든 상자 (S-046)
                ForEach(model.mailboxes.smart) { box in
                    Label(box.name, systemImage: box.symbol)
                        .tag(box.id)
                        .help(box.summary { id in model.folders.first { $0.id == id }?.displayName })
                        .contextMenu {
                            Button(L("스마트 메일상자 변경…")) { model.editingSmart = box }
                            Button(L("스마트 메일상자 지우기…"), role: .destructive) {
                                if TextPrompt.confirm(L("\"\(box.name)\" 스마트 메일상자를 지울까요?"),
                                                      message: L("메일은 지워지지 않고 원래 폴더에 남습니다."), action: L("지우기")) {
                                    model.removeSmart(id: box.id)
                                }
                            }
                        }
                }
            }
            } header: {
                SidebarSectionHeader(title: L("스마트 메일상자"), isExpanded: expanded("smart"))
            }
            // VIP (S-045): 사람마다 이름과 아이콘
            if !model.mailboxes.vips.isEmpty {
                Section {
                if expanded("vip").wrappedValue {
                    Label(L("모든 VIP"), systemImage: "star")
                        .tag(VirtualMailbox.allVIPsID)
                    ForEach(model.mailboxes.vips) { vip in
                        Label(vip.title, systemImage: vip.symbol)
                            .tag(VirtualMailbox.id(forVIP: vip.address))
                            .help(vip.address)
                            .contextMenu {
                                Button(L("이름·아이콘 변경…")) { model.editingVIP = vip }
                                Button(L("VIP에서 빼기")) { model.removeVIP(address: vip.address) }
                            }
                    }
                }
            } header: {
                    SidebarSectionHeader(title: "VIP", isExpanded: expanded("vip"))  // l10n: data
                }
            }
            // 계정마다 구역 (M23). 계정이 하나면 예전과 같다.
            ForEach(model.accounts.accounts) { account in
            Section {
                if expanded("account.\(account.id)").wrappedValue {
                ForEach(model.accountFolders[account.id] ?? []) { folder in
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
            } header: {
                SidebarSectionHeader(title: model.accounts.title(for: account),
                                     isExpanded: expanded("account.\(account.id)"),
                                     unread: inboxUnread(account),
                                     newFolder: { newFolder(parent: nil, account: account) })
            }
            }
            // 나의 Mac에 (S-055): 가져온 메일상자. 서버와 상관없이 이 Mac에 저장되어 있다.
            if !model.localBoxes.boxes.isEmpty {
                Section {
                if expanded("local").wrappedValue {
                    ForEach(model.localBoxes.boxes) { box in
                        Label(box.name, systemImage: "tray.full")
                            .tag(box.sidebarID)
                            .help(L("이 Mac에 저장한 메일 \(box.count)통"))
                            .contextMenu {
                                Button(L("이름 변경…")) { model.renameLocal(box) }
                                Button(L("메일상자 내보내기…")) { model.exportLocal(box) }
                                Button(L("Finder에서 보기")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([model.localBoxes.fileURL(box)])
                                }
                                Divider()
                                Button(L("메일상자 지우기…"), role: .destructive) { model.removeLocal(box) }
                            }
                    }
                }
            } header: {
                    SidebarSectionHeader(title: L("나의 Mac에"), isExpanded: expanded("local"))
                }
            }
        }
        // 사이드바는 스크롤 막대를 그리지 않는다 (휠·트랙패드로는 스크롤된다). 시스템 설정 "스크롤 막대 보기: 항상"이면
        // 구역을 펼쳐 목록이 길어질 때만 막대가 생겨, 그 폭만큼 구역 이름의 ⌄·새 폴더 단추가 좌우로 움직였다 (docs/FIXLOG.md)
        .scrollIndicators(.never, axes: .vertical)
        .contextMenu {
            Button(L("새 폴더…")) { newFolder(parent: nil) }
            Button(L("메일상자 가져오기…")) { model.importLocalMailbox() }
            Button(L("새 스마트 메일상자…")) { model.newSmartMailbox() }
        }
        .overlay {
            if model.folders.isEmpty && model.isLoading {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: MailFolder) -> some View {
        Button(L("새 하위 폴더…")) { newFolder(parent: folder) }
        Divider()
        Button(L("이름 변경…")) {
            if let name = TextPrompt.ask(L("폴더 이름 변경"), initial: folder.displayName, confirm: L("변경")) {
                Task { await model.renameFolder(folder, to: name) }
            }
        }
        .disabled(!folder.isEditable)
        Button(L("폴더 지우기…"), role: .destructive) {
            if TextPrompt.confirm(L("\"\(folder.displayName)\" 폴더를 지울까요?"),
                                  message: L("폴더와 안의 메일, 하위 폴더가 지운 편지함으로 옮겨집니다."), action: L("지우기")) {
                Task { await model.deleteFolder(folder) }
            }
        }
        .disabled(!folder.isEditable)
    }

    /// 계정 구역을 접었을 때 보이는 수: 그 계정 받은 편지함의 읽지 않은 메일
    private func inboxUnread(_ account: MailAccount) -> Int {
        model.accountFolders[account.id]?.first { $0.kind == "inbox" }?.unreadItemCount ?? 0
    }

    /// 구역 이름 옆 새 폴더 단추: 그 계정의 맨 위에 만든다
    private func newFolder(parent: MailFolder?, account: MailAccount) {
        model.activateAccount(account.id)
        newFolder(parent: parent)
    }

    private func newFolder(parent: MailFolder?) {
        let message = parent.map { L("\"\($0.displayName)\" 안에 만듭니다.") } ?? ""
        if let name = TextPrompt.ask(L("새 폴더"), message: message, confirm: L("만들기")) {
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

/// 사이드바 구역 이름 (맥 Mail): 접혀 있으면 읽지 않은 수. 마우스를 올리면 새 폴더 단추(계정만)와 ⌄·›.
/// 단추 자리는 늘 잡아 두고 보이기만 바꾼다 (자리가 바뀌면 옆 내용이 밀려 흔들린다).
struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    var unread = 0
    var newFolder: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: Space.sm)
            if !isExpanded && unread > 0 {
                Text(unread, format: .number)
                    .monospacedDigit()
            }
            if let newFolder {
                Button(action: newFolder) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(L("새 폴더…"))
                .accessibilityLabel(L("새 폴더…"))
                .opacity(hovering ? 1 : 0)
            }
            Button {
                isExpanded.toggle()
            } label: {
                // 같은 그림을 돌린다: ⌄와 ›를 다른 그림으로 쓰면 폭이 달라 자리가 흔들린다
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Space.lg, height: Space.lg)
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? L("접기") : L("펼치기"))
            .accessibilityLabel(isExpanded ? L("접기") : L("펼치기"))
            .opacity(hovering ? 1 : 0)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 스크롤 막대는 겹쳐 그린다: 구역을 펼쳐 목록이 길어질 때 막대가 생기면(시스템 설정 "항상")
        // 그 폭만큼 이 단추들이 왼쪽으로 밀렸다
        .overlayScrollers()
    }
}
