import SwiftUI
import ExchangeMailKit

/// 로그인 전 화면 (S-001).
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("azureClientID") private var clientID = ""
    @AppStorage("azureTenant") private var tenant = ""

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
                Text(L("Microsoft 365 / Exchange Online 계정으로 로그인합니다.\n처음 한 번만 Azure 앱의 클라이언트 ID를 넣으세요."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField(L("클라이언트 ID"), text: $clientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                TextField(L("테넌트"), text: $tenant, prompt: Text(L("비우면 common")))
                LabeledContent(L("리디렉션 URI")) {
                    Text(model.auth.redirectURI)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 480, height: 168)
            Button {
                Task { await model.auth.signIn() }
            } label: {
                if model.auth.isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L("Microsoft로 로그인"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || model.auth.isSigningIn)
            .keyboardShortcut(.defaultAction)
            if let error = model.auth.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: 480)
            }
            Text(L("Azure 앱 등록 방법은 README의 \"Azure 앱 등록\"을 보세요."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noInitialFocus()
    }
}
