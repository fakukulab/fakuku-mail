import AppKit
import ExchangeMailKit
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic. Each tab is a grouped Form
/// that sizes to its content, except Signatures, which needs room for the editor.
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

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .signatures:
            SignatureSettings()
                .frame(width: 820, height: 560)
        default:
            Form {
                switch tab {
                case .account: AccountSettings()
                case .attachments: AttachFixSettings()
                case .notifications: NotificationSettings()
                case .appearance: AppearanceSettings()
                case .signatures: EmptyView()
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .frame(width: 560)
        }
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case account, signatures, attachments, notifications, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "계정"
        case .signatures: "서명"
        case .attachments: "첨부 보정"
        case .notifications: "알림"
        case .appearance: "모양"
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .signatures: "signature"
        case .attachments: "paperclip"
        case .notifications: "bell.badge"
        case .appearance: "paintpalette"
        }
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("azureClientID") private var clientID = ""
    @AppStorage("azureTenant") private var tenant = ""

    var body: some View {
        Section("Microsoft Exchange") {
            if model.isDemo {
                LabeledContent("데모 모드", value: model.auth.email ?? "")
                Text("예시 메일로 도는 모드입니다. 서버에 연결하지 않습니다.")
                    .foregroundStyle(.secondary)
            } else if let email = model.auth.email {
                LabeledContent("로그인됨") {
                    VStack(alignment: .trailing) {
                        if let name = model.auth.displayName { Text(name) }
                        Text(email).foregroundStyle(.secondary)
                    }
                }
                Button("로그아웃", role: .destructive) { model.auth.signOut() }
            } else {
                Button("Microsoft로 로그인") { Task { await model.auth.signIn() } }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.auth.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        Section {
            TextField("클라이언트 ID", text: $clientID)
            TextField("테넌트", text: $tenant, prompt: Text("비우면 common"))
            LabeledContent("리디렉션 URI") {
                Text(model.auth.redirectURI)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Azure 앱 등록")
        } footer: {
            Text("API 권한(위임): User.Read, Mail.ReadWrite, Mail.Send, offline_access. 바꾼 값은 다음 로그인부터 쓰입니다.")
                .foregroundStyle(.secondary)
        }
    }
}

struct AttachFixSettings: View {
    @AppStorage("fixEnabled") private var enabled = true
    @AppStorage("fixImagesAsAttachments") private var images = true
    @AppStorage("fixEUCKR") private var eucKR = false
    @AppStorage("fixMinKB") private var minKB = 0

    var body: some View {
        Section {
            Toggle("새 메일에 첨부 보정 켜기", isOn: $enabled)
            Toggle("본문 그림을 일반 첨부파일로 보내기", isOn: $images)
            Stepper(value: $minKB, in: 0...2048, step: 10) {
                LabeledContent("이보다 작은 그림은 본문에 두기", value: minKB == 0 ? "모두 첨부" : "\(minKB) KB")
            }
            .disabled(!images)
            Toggle("EUC-KR 파일명 (구형 국내 시스템용)", isOn: $eucKR)
        } header: {
            Text("기본값")
        } footer: {
            Text("작성 창의 \"첨부 보정\" 체크로 메일마다 끄고 켤 수 있습니다. EUC-KR로 쓸 수 없는 글자가 있으면 UTF-8로 보냅니다.")
                .foregroundStyle(.secondary)
        }
        Section("항상 적용") {
            Label("한글 파일명을 완성형(NFC)으로 바꿉니다.", systemImage: "textformat")
            Label("파일명을 RFC 2047과 RFC 2231로 함께 기록해 Windows·Outlook에서도 한글로 보입니다.", systemImage: "doc.text")
            Label("서명과 인용문 안의 그림은 본문에 그대로 둡니다.", systemImage: "signature")
        }
    }
}

/// 설정 > 알림 (S-024)
struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("notify.newMail") private var newMail = true
    @AppStorage("notify.sound") private var sound = true
    @AppStorage("notify.badge") private var badge = true

    var body: some View {
        Section {
            Toggle("새 메일 알림", isOn: $newMail)
                .onChange(of: newMail) { _, on in
                    if on { Task { await model.prepareNotifications() } }
                }
            Toggle("알림 소리", isOn: $sound)
                .disabled(!newMail)
            if newMail && model.notificationPermission == .denied {
                LabeledContent {
                    Button("시스템 설정 열기") { openSystemSettings() }
                } label: {
                    Label("macOS 알림 권한이 꺼져 있습니다.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("받은 편지함")
        } footer: {
            Text("앱이 켜져 있는 동안 2분마다 확인합니다. 앱이 앞에 있으면 배너 없이 알림 센터에만 남습니다.")
                .foregroundStyle(.secondary)
        }
        Section("Dock") {
            Toggle("읽지 않은 메일 수 배지", isOn: $badge)
                .onChange(of: badge) { _, _ in model.updateBadge() }
        }
        .task { await model.refreshNotificationPermission() }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
