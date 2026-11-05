import AppKit
import ExchangeMailKit
import SwiftUI

/// iCloud·Gmail 계정 추가 시트 (M24). 이메일과 앱 암호를 넣으면 메일 서버에 로그인해 보고, 되면 계정을 더한다.
/// 앱 암호: 계정 암호 대신 이 앱에만 주는 암호 (iCloud는 account.apple.com, Gmail은 Google 계정 > 보안).
struct IMAPAccountSheet: View {
    let provider: IMAPAccountConfig.Provider
    /// 계정을 더하면 (그 계정 id)
    var added: (String) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?

    private var config: IMAPAccountConfig {
        let address = email.trimmingCharacters(in: .whitespaces)
        let who = name.trimmingCharacters(in: .whitespaces)
        return provider == .gmail ? .gmail(email: address, name: who) : .icloud(email: address, name: who)
    }

    private var isValid: Bool {
        AddressParser.parse(email).valid.count == 1 && !password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var title: String { provider == .gmail ? L("Gmail 계정 추가") : L("iCloud 계정 추가") }

    private var helpURL: URL {
        provider == .gmail ? URL(string: "https://myaccount.google.com/apppasswords")!  // l10n: data
            : URL(string: "https://account.apple.com/account/manage")!  // l10n: data
    }

    var body: some View {
        Form {
            Section {
                TextField(L("이름"), text: $name, prompt: Text(L("받는 사람에게 보일 이름")))
                TextField(L("이메일"), text: $email,
                          prompt: Text(provider == .gmail ? "name@gmail.com" : "name@icloud.com"))  // l10n: data
                    .textContentType(.username)
                SecureField(L("앱 암호"), text: $password, prompt: Text("xxxx-xxxx-xxxx-xxxx"))  // l10n: data
                    .onSubmit(add)
            } header: {
                Text(title)
            } footer: {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(provider == .gmail
                         ? L("Google 계정 암호가 아니라 앱 비밀번호를 넣습니다. 2단계 인증을 켠 뒤 Google 계정 > 보안 > 앱 비밀번호에서 만듭니다.")
                         : L("Apple 계정 암호가 아니라 앱 암호를 넣습니다. Apple 계정 > 로그인 및 보안 > 앱 암호에서 만듭니다."))
                        .foregroundStyle(.secondary)
                    Link(provider == .gmail ? L("앱 비밀번호 만들기…") : L("앱 암호 만들기…"), destination: helpURL)
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 460)
        .disabled(working)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("취소")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: add) {
                    if working { ProgressView().controlSize(.small) } else { Text(L("로그인")) }
                }
                .disabled(!isValid || working)
            }
        }
        .noInitialFocus()
    }

    private func add() {
        guard isValid, !working else { return }
        working = true
        problem = nil
        let config = config
        let secret = password.trimmingCharacters(in: .whitespaces)
        Task {
            defer { working = false }
            do {
                try await model.addIMAPAccount(config, password: secret)
                if let id = model.accounts.accounts.last?.id { added(id) }
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

extension MailAccount {
    /// 계정 목록의 그림
    var symbol: String {
        switch imap?.provider {
        case .icloud: "icloud"
        case .gmail: "envelope"
        case .other: "server.rack"
        case nil: "envelope.badge.person.crop"
        }
    }

    /// 계정 목록의 종류 이름
    var providerTitle: String { imap?.providerName ?? "Microsoft Exchange" }  // l10n: data
}
