import AppKit
import ExchangeMailKit
import SwiftUI

/// The Settings window (Command-Comma), laid out like Mail's (S-048): one tab per topic, labels right-aligned
/// in the left column and controls in the right (`.formStyle(.columns)`). Signatures, rules, and auto reply
/// edit lists, so they keep their own layouts. Every tab has the same size (`SettingsView.size`).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    /// 모든 탭이 같은 크기: 탭을 바꿔도 창이 줄거나 늘지 않는다. 넘치면 탭 안에서 스크롤한다.
    static let size = CGSize(width: 760, height: 560)

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .signatures:
            SignatureSettings()
                .frame(width: Self.size.width, height: Self.size.height)
        case .rules, .autoReply:
            Form {
                if tab == .rules { RulesSettings() } else { AutoReplySettings() }
            }
            .formStyle(.grouped)
            .frame(width: Self.size.width, height: Self.size.height)
        default:
            ScrollView {
                Form {
                    switch tab {
                    case .general: GeneralSettings()
                    case .account: AccountSettings()
                    case .junk: JunkSettings()
                    case .viewing: ViewingSettings()
                    case .composing: ComposingSettings()
                    case .notifications: NotificationSettings()
                    default: EmptyView()
                    }
                }
                .formStyle(.columns)
                .padding(.horizontal, Space.section)
                .padding(.vertical, Space.xl)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }
}

/// The Settings tabs, in Mail's order. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, account, junk, viewing, composing, signatures, rules, autoReply, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "일반"
        case .account: "계정"
        case .junk: "정크 메일"
        case .viewing: "보기"
        case .composing: "작성"
        case .signatures: "서명"
        case .rules: "규칙"
        case .autoReply: "자동 응답"
        case .notifications: "알림"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: "at"
        case .junk: "xmark.bin"
        case .viewing: "eyeglasses"
        case .composing: "square.and.pencil"
        case .signatures: "signature"
        case .rules: "line.3.horizontal.decrease.circle"
        case .autoReply: "arrowshape.turn.up.backward.badge.clock"
        case .notifications: "bell.badge"
        }
    }
}

/// 설명 글: 오른쪽 열, 작고 흐리게
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 일반

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("refresh.minutes") private var refreshMinutes = 2
    @AppStorage("notify.badge") private var badge = true

    var body: some View {
        Section {
            Picker("새 메일 확인:", selection: $refreshMinutes) {
                Text("1분마다").tag(1)
                Text("2분마다").tag(2)
                Text("5분마다").tag(5)
                Text("15분마다").tag(15)
                Text("수동").tag(0)
            }
            .fixedSize()
            LabeledContent("Dock 배지:") {
                Toggle("읽지 않은 메일 수 보이기", isOn: $badge)
                    .onChange(of: badge) { _, _ in model.updateBadge() }
            }
        }
        OfflineSettings()
        AppearanceSettings()
    }
}

/// 설정 > 일반 > 오프라인 (S-026)
struct OfflineSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cache.enabled") private var enabled = true
    @State private var size = 0

    var body: some View {
        Section {
            LabeledContent("오프라인:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("최근 메일을 이 Mac에 저장", isOn: $enabled)
                        .onChange(of: enabled) { _, on in
                            if !on { clear() }
                        }
                    HStack(spacing: Space.sm) {
                        Text("저장된 메일 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("지우기") { clear() }
                            .controlSize(.small)
                            .disabled(size == 0)
                    }
                    SettingsNote("네트워크가 없을 때 최근 목록과 열어 본 메일을 보여 줍니다. 로그아웃하면 지웁니다.")
                }
            }
        }
        .task { size = model.cachedService?.cache?.sizeBytes() ?? 0 }
    }

    private func clear() {
        model.cachedService?.clearCache()
        size = 0
    }
}

// MARK: 계정

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("azureClientID") private var clientID = ""
    @AppStorage("azureTenant") private var tenant = ""

    var body: some View {
        Section {
            LabeledContent("Microsoft Exchange:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if model.isDemo {
                        Text(model.auth.email ?? "")
                        SettingsNote("데모 모드: 예시 메일로 돌며 서버에 연결하지 않습니다.")
                    } else if let email = model.auth.email {
                        if let name = model.auth.displayName { Text(name) }
                        Text(email).foregroundStyle(.secondary)
                        Button("로그아웃", role: .destructive) { model.signOut() }
                    } else {
                        Text("로그인하지 않음").foregroundStyle(.secondary)
                        Button("Microsoft로 로그인") { Task { await model.auth.signIn() } }
                            .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let error = model.auth.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        Section {
            TextField("클라이언트 ID:", text: $clientID)
            TextField("테넌트:", text: $tenant, prompt: Text("비우면 common"))
            LabeledContent("리디렉션 URI:") {
                Text(model.auth.redirectURI)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("") {
                SettingsNote("Azure 앱 등록의 API 권한(위임): User.Read, Mail.ReadWrite, Mail.Send, offline_access, "
                             + "Calendars.ReadWrite, MailboxSettings.ReadWrite. 바꾼 값은 다음 로그인부터 쓰입니다.")
            }
        }
    }
}

// MARK: 정크 메일

struct JunkSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent("걸러내기:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Exchange Online이 서버에서 정크 메일을 걸러 정크 메일 폴더로 옮깁니다.")
                    SettingsNote("차단한 보낸 사람과 안전한 보낸 사람 목록은 Outlook 웹에서 관리합니다. 이 Mac과 다른 기기에 모두 적용됩니다.")
                    Button("Outlook 웹 정크 메일 설정 열기…") {
                        if let url = URL(string: "https://outlook.office.com/mail/options/mail/junkEmail") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            LabeledContent("정크로 표시:") {
                SettingsNote("메시지 > 정크 메일로 표시(⇧⌘J)는 메일을 정크 메일 폴더로 옮겨 Exchange가 배우게 합니다. "
                             + "정크 메일 폴더에서는 같은 메뉴가 \"정크 아님\"이 되어 받은 편지함으로 돌려놓습니다.")
            }
        }
        Section {
            LabeledContent("정크 메일 폴더:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("원격 그림을 항상 막기", isOn: $model.junkBlocksRemote)
                    SettingsNote("메일 활동 보호를 켜 두어도 정크 메일의 원격 그림은 받지 않습니다.")
                }
            }
        }
    }
}

// MARK: 보기

struct ViewingSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("list.threaded") private var threaded = true

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent("목록:") {
                Toggle("대화별로 정리", isOn: $threaded)
            }
            Picker("정렬 기준:", selection: $model.listSort.key) {
                ForEach(MailSort.Key.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Picker("순서:", selection: $model.listSort.descending) {
                Text(model.listSort.key == .date ? "새로운 항목 우선" : "내림차순").tag(true)
                Text(model.listSort.key == .date ? "오래된 항목 우선" : "오름차순").tag(false)
            }
            .fixedSize()
        }
        Section {
            LabeledContent("개인정보 보호:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("메일 활동 보호", isOn: $model.protectMailActivity)
                    SettingsNote("추적 픽셀과 알려진 추적 서비스를 막고, 나머지 원격 그림은 앱이 쿠키·리퍼러 없이 대신 받아 "
                                 + "보여 줍니다. 보낸 사람은 메일을 언제 열었는지 알 수 없습니다. "
                                 + "IP 주소는 숨기지 않습니다(중계 서버가 필요해서).")
                    Toggle("모든 원격 콘텐츠 차단", isOn: $model.blockAllRemote)
                        .disabled(model.protectMailActivity)
                        .padding(.top, Space.sm)
                    SettingsNote("메일 활동 보호를 끈 경우에만 씁니다. 켜면 원격 그림을 받지 않고, 메일마다 \"불러오기\"로 볼 수 있습니다.")
                }
            }
        }
    }
}

// MARK: 작성

struct ComposingSettings: View {
    @AppStorage("send.undoDelay") private var undoDelay = 10
    @AppStorage("fixEnabled") private var fixEnabled = true
    @AppStorage("fixImagesAsAttachments") private var images = true
    @AppStorage("fixEUCKR") private var eucKR = false
    @AppStorage("fixMinKB") private var minKB = 0

    var body: some View {
        Section {
            Picker("보내기 취소:", selection: $undoDelay) {
                Text("끔").tag(0)
                Text("5초").tag(5)
                Text("10초").tag(10)
                Text("20초").tag(20)
            }
            .fixedSize()
            LabeledContent("") {
                SettingsNote("보내기를 누른 뒤 이 시간 동안 작성 창에서 \"보내기 취소\"를 누를 수 있습니다.")
            }
        }
        Section {
            LabeledContent("첨부 보정:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("새 메일에 첨부 보정 켜기", isOn: $fixEnabled)
                    Toggle("본문 그림을 일반 첨부파일로 보내기", isOn: $images)
                    Stepper(value: $minKB, in: 0...2048, step: 10) {
                        Text(minKB == 0 ? "모든 그림을 첨부로" : "\(minKB) KB보다 작은 그림은 본문에 두기")
                    }
                    .disabled(!images)
                    Toggle("EUC-KR 파일명 (구형 국내 시스템용)", isOn: $eucKR)
                    SettingsNote("작성 창의 \"첨부 보정\" 체크로 메일마다 끄고 켤 수 있습니다. EUC-KR로 쓸 수 없는 글자가 있으면 UTF-8로 보냅니다.")
                }
            }
            LabeledContent("항상 적용:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label("한글 파일명을 완성형(NFC)으로 바꿉니다.", systemImage: "textformat")
                    Label("파일명을 RFC 2047과 RFC 2231로 함께 기록해 Windows·Outlook에서도 한글로 보입니다.", systemImage: "doc.text")
                    Label("서명과 인용문 안의 그림은 본문에 그대로 둡니다.", systemImage: "signature")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: 알림 (S-024)

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("notify.newMail") private var newMail = true
    @AppStorage("notify.sound") private var sound = true

    var body: some View {
        Section {
            LabeledContent("새 메일:") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("받은 편지함에 새 메일이 오면 알리기", isOn: $newMail)
                        .onChange(of: newMail) { _, on in
                            if on { Task { await model.prepareNotifications() } }
                        }
                    Toggle("알림 소리", isOn: $sound)
                        .disabled(!newMail)
                    if newMail && model.notificationPermission == .denied {
                        HStack(spacing: Space.sm) {
                            Label("macOS 알림 권한이 꺼져 있습니다.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Button("시스템 설정 열기") { openSystemSettings() }
                                .controlSize(.small)
                        }
                    }
                    SettingsNote("설정 > 일반의 간격마다 확인합니다. 앱이 앞에 있으면 배너 없이 알림 센터에만 남습니다.")
                }
            }
        }
        .task { await model.refreshNotificationPermission() }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
