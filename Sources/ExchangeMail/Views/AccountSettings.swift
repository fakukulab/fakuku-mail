import AppKit
import ExchangeMailKit
import SwiftUI

/// 설정 > 계정 (M23): 맥 Mail처럼 왼쪽에 계정 목록과 + −, 오른쪽에 고른 계정의
/// "계정 정보 · 메일상자 동작 · 서버 설정".
struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var page = Page.info

    enum Page: String, CaseIterable, Identifiable {
        case info, mailboxes, server
        var id: String { rawValue }
        var title: String {
            switch self {
            case .info: L("계정 정보")
            case .mailboxes: L("메일상자 동작")
            case .server: L("서버 설정")
            }
        }
    }

    private var selected: MailAccount? {
        model.accounts.accounts.first { $0.id == selection } ?? model.accounts.accounts.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            sidebar
                .frame(width: 240)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: Space.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Space.sm, style: .continuous).strokeBorder(.separator))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { if selection == nil { selection = model.accounts.active?.id } }
    }

    // MARK: 왼쪽: 계정 목록, + −

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.accounts.accounts) { account in
                    HStack(spacing: Space.sm) {
                        Image(systemName: "envelope.badge.person.crop")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.accounts.title(for: account))
                                .lineLimit(1)
                            Text("Microsoft Exchange")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Space.xs)
                    .tag(account.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.accounts.accounts.isEmpty {
                    ContentUnavailableView(L("계정 없음"), systemImage: "at",
                                           description: Text(L("+를 눌러 계정을 추가하세요.")))
                }
            }
            if let error = model.accounts.pending.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Space.sm)
            }
            Divider()
            HStack(spacing: Space.xs) {
                // 계정 추가: 지금은 Exchange. Gmail·iCloud는 다음 단계 (M24, M25).
                Menu {
                    Button(L("Microsoft Exchange…")) {
                        Task {
                            await model.addAccount()
                            selection = model.accounts.accounts.last?.id
                        }
                    }
                    .disabled(model.isDemo || model.accounts.pending.clientID.isEmpty)
                    Divider()
                    Button(L("Gmail (곧 추가)")) {}.disabled(true)
                    Button(L("iCloud (곧 추가)")) {}.disabled(true)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("계정 추가"))
                .disabled(model.accounts.pending.isSigningIn)
                Button(L("계정 삭제"), systemImage: "minus") { removeSelected() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(L("고른 계정에서 로그아웃하고 목록에서 뺍니다"))
                    .disabled(model.isDemo || selected == nil)
                if model.accounts.pending.isSigningIn {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(Space.sm)
        }
    }

    private func removeSelected() {
        guard let account = selected else { return }
        if TextPrompt.confirm(L("\(account.email) 계정에서 로그아웃할까요?"),
                              message: L("이 Mac에 저장한 그 계정의 메일을 지웁니다. 서버의 메일은 그대로입니다."),
                              action: L("로그아웃")) {
            model.signOut(accountID: account.id)
            selection = model.accounts.accounts.first?.id
        }
    }

    // MARK: 오른쪽: 고른 계정

    @ViewBuilder
    private var detail: some View {
        if let account = selected {
            VStack(spacing: Space.lg) {
                Picker(L("보기"), selection: $page) {
                    ForEach(Page.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        switch page {
                        case .info: AccountInfoPage(account: account)
                        case .mailboxes: AccountMailboxPage(account: account)
                        case .server: AccountServerPage(account: account)
                        }
                    }
                    .labeledContentStyle(AccountRowStyle())
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, Space.sm)
                }
            }
        } else {
            ContentUnavailableView(L("계정을 고르세요"), systemImage: "at")
        }
    }
}

/// 계정 탭의 한 줄: 오른쪽 맞춘 레이블 + 왼쪽 맞춘 내용 (설정 줄과 같지만 오른쪽 칸이 좁아 레이블 열을 줄였다)
struct AccountRowStyle: LabeledContentStyle {
    static let labelWidth: CGFloat = 136

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            configuration.label
                .frame(width: Self.labelWidth, alignment: .trailing)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: 계정 정보

private struct AccountInfoPage: View {
    let account: MailAccount
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent(L("상태:")) {
            HStack(spacing: Space.sm) {
                Text(account.service.isOffline ? L("오프라인") : L("온라인"))
                Circle()
                    .fill(account.service.isOffline ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        LabeledContent(L("설명:")) {
            TextField(L("설명"), text: Binding(
                get: { model.accounts.descriptions[account.id] ?? "" },
                set: { model.accounts.setDescription($0, for: account.id) }),
                      prompt: Text(account.email))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
        LabeledContent(L("이메일 주소:")) {
            Text(account.auth.displayName.map { "\($0) <\(account.email)>" } ?? account.email)
                .textSelection(.enabled)
        }
        if model.isDemo {
            LabeledContent("") {
                SettingsNote(L("데모 모드: 예시 메일로 돌며 서버에 연결하지 않습니다."))
            }
        }
        Divider()
        MacCalendarSettings()
    }
}

// MARK: 메일상자 동작

private struct AccountMailboxPage: View {
    let account: MailAccount
    @Environment(AppModel.self) private var model

    private func name(_ kind: String) -> String {
        model.accountFolders[account.id]?.first { $0.kind == kind }?.displayName ?? "—"
    }

    var body: some View {
        LabeledContent(L("임시 보관함:")) { Text(name("drafts")) }
        LabeledContent(L("보낸 편지함:")) { Text(name("sentitems")) }
        LabeledContent(L("정크 메일:")) { Text(name("junkemail")) }
        LabeledContent(L("지운 편지함:")) { Text(name("deleteditems")) }
        LabeledContent(L("보관:")) { Text(name("archive")) }
        LabeledContent("") {
            SettingsNote(L("Exchange 계정은 서버가 정한 폴더를 씁니다. 보낸 메일은 서버가 보낸 편지함에 저장하고, ")
                         + L("지운 메일은 지운 편지함으로 옮깁니다."))
        }
    }
}

// MARK: 서버 설정

private struct AccountServerPage: View {
    let account: MailAccount
    @AppStorage("azureClientID") private var clientID = ""
    @AppStorage("azureTenant") private var tenant = ""
    @State private var showAdvanced = GraphAuth.bundledClientID.isEmpty

    var body: some View {
        LabeledContent(L("서버:")) { Text("Microsoft Exchange Online (Microsoft Graph)") }
        LabeledContent(L("로그인:")) { Text(L("Microsoft 계정 (Microsoft 로그인 창)")) }
        LabeledContent(L("사용자 이름:")) {
            Text(account.email).textSelection(.enabled)
        }
        Divider()
        // 고급: 회사가 자체 Azure 앱 등록을 쓸 때만 (S-058). 새로 로그인하는 계정에 쓰인다.
        LabeledContent(L("앱 등록:")) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Button(showAdvanced ? L("고급 설정 숨기기") : L("고급 설정 보기…")) { showAdvanced.toggle() }
                    .buttonStyle(.link)
                if !showAdvanced && (!clientID.isEmpty || !tenant.isEmpty) {
                    SettingsNote(L("직접 넣은 앱 등록 값을 쓰고 있습니다."))
                }
            }
        }
        if showAdvanced {
            LabeledContent(L("클라이언트 ID:")) {
                TextField(L("클라이언트 ID"), text: $clientID,
                          prompt: Text(GraphAuth.bundledClientID.isEmpty ? "00000000-0000-0000-0000-000000000000" : L("비우면 앱 기본값")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            LabeledContent(L("테넌트:")) {
                TextField(L("테넌트"), text: $tenant, prompt: Text(L("비우면 common")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            LabeledContent(L("리디렉션 URI:")) {
                Text(account.auth.redirectURI)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SettingsNote(L("회사가 자체 Azure 앱 등록을 쓰는 경우에만 넣습니다. 비워 두면 FAKUKU Mail의 앱 등록을 씁니다. ")
                                 + L("바꾼 값은 다음 로그인부터 쓰입니다."))
                    Button(L("기본값으로 되돌리기")) {
                        clientID = ""
                        tenant = ""
                    }
                    .controlSize(.small)
                    .disabled(clientID.isEmpty && tenant.isEmpty)
                }
            }
        }
    }
}

// MARK: 맥 캘린더 (S-056)

private struct MacCalendarSettings: View {
    @AppStorage(Prefs.calendarAddAccepted) private var addAccepted = true
    @AppStorage(Prefs.calendarTarget) private var calendarTarget = ""
    @State private var calendars: [(id: String, title: String)] = []
    @State private var calendarAccess = MacCalendar.shared.hasAccess

    var body: some View {
        LabeledContent(L("맥 캘린더:")) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Toggle(L("수락한 회의를 맥 캘린더에 추가"), isOn: $addAccepted)
                if calendarAccess {
                    Picker(L("넣을 캘린더"), selection: $calendarTarget) {
                        Text(L("기본 캘린더")).tag("")
                        ForEach(calendars, id: \.id) { c in Text(c.title).tag(c.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!addAccepted)
                } else {
                    Button(L("캘린더 접근 허용…")) {
                        Task {
                            calendarAccess = await MacCalendar.shared.requestAccess()
                            if !calendarAccess { MacCalendar.openPrivacySettings() }
                            load()
                        }
                    }
                    .controlSize(.small)
                }
                SettingsNote(L("수락·미정으로 답한 회의를 넣고, 거절하면 앱이 넣은 일정을 지웁니다. ")
                             + L("같은 시각에 같은 제목의 일정이 이미 있으면(Exchange 동기화 등) 넣지 않습니다."))
            }
        }
        .task { load() }
    }

    private func load() {
        calendarAccess = MacCalendar.shared.hasAccess
        calendars = MacCalendar.shared.writableCalendars().map { (id: $0.calendarIdentifier, title: "\($0.title) — \($0.source.title)") }
    }
}
