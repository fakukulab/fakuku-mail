import AppKit
import ExchangeMailKit
import SwiftUI

/// 로그인 전 화면 (S-001, S-058). 이메일만 넣고 "로그인"을 누르면 Microsoft 로그인 창이 열리고,
/// 비밀번호와 다중 인증은 그 창에서 한다. 앱 등록 번호(클라이언트 ID)는 앱에 들어 있어 사용자가 몰라도 된다.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("azureClientID") private var clientID = ""
    @AppStorage("azureTenant") private var tenant = ""
    /// 지난번에 넣은 이메일 (다시 로그인할 때 채워 둔다)
    @AppStorage("signIn.lastEmail") private var email = ""
    @State private var showAdvanced = GraphAuth.bundledClientID.isEmpty
    @State private var copied = false

    private var hasClientID: Bool { !model.auth.clientID.isEmpty }

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: Space.sm) {
                Text("FAKUKU Mail")
                    .font(.largeTitle.bold())
                Text(L("Exchange 계정으로 시작하기"))
                    .font(.title3)
                Text(L("회사 이메일 주소를 넣고 로그인하세요.\n비밀번호와 휴대폰 승인은 Microsoft 로그인 창에서 합니다."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Space.md) {
                TextField(L("이메일"), text: $email, prompt: Text("name@company.com"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit { signIn() }
                Button {
                    signIn()
                } label: {
                    if model.auth.isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("로그인"))
                            .frame(minWidth: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasClientID || model.auth.isSigningIn)
                .keyboardShortcut(.defaultAction)
            }
            if let error = model.auth.lastError {
                VStack(spacing: Space.sm) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .frame(maxWidth: 480)
                    // 회사가 관리자 승인을 요구하면: 관리자에게 보낼 링크
                    if model.auth.needsAdminConsent, let link = model.auth.adminConsentURL {
                        Text(L("회사에서 처음 쓰는 앱은 IT 관리자의 승인이 한 번 필요할 수 있습니다. 아래 링크를 관리자에게 보내 주세요."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 480)
                        Button(copied ? L("복사했습니다") : L("관리자 승인 링크 복사")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
            }
            DisclosureGroup(L("고급"), isExpanded: $showAdvanced) {
                Form {
                    TextField(L("클라이언트 ID"), text: $clientID,
                              prompt: Text(GraphAuth.bundledClientID.isEmpty ? "00000000-0000-0000-0000-000000000000" : L("비우면 앱 기본값")))
                    TextField(L("테넌트"), text: $tenant, prompt: Text(L("비우면 common")))
                    LabeledContent(L("리디렉션 URI")) {
                        Text(model.auth.redirectURI)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 168)
                Text(L("회사가 자체 Azure 앱 등록을 쓰는 경우에만 넣습니다. 방법은 README의 \"Azure 앱 등록\"을 보세요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 480)
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noInitialFocus()
    }

    private func signIn() {
        guard hasClientID, !model.auth.isSigningIn else { return }
        copied = false
        let address = email.trimmingCharacters(in: .whitespaces)
        Task { await model.auth.signIn(email: address.isEmpty ? nil : address) }
    }
}
