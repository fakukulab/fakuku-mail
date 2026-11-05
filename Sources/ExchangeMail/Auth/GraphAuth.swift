import AppKit
import AuthenticationServices
import ExchangeMailKit
import Foundation
import Observation

/// Microsoft 365 / Exchange Online 로그인 (OAuth2 Authorization Code + PKCE).
/// Azure 앱 등록: 플랫폼 "모바일 및 데스크톱 애플리케이션", 리디렉션 URI = `msauth.<번들ID>://auth`
@Observable
final class GraphAuth: NSObject {

    struct TokenSet: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String
        var name: String?
        /// 로그인할 때 쓴 앱 등록 번호와 테넌트. 토큰을 갱신할 때 같은 값을 쓴다 (예전 토큰에는 없다).
        var clientID: String? = nil
        var tenant: String? = nil
    }

    private(set) var email: String?
    private(set) var displayName: String?
    private(set) var isSigningIn = false
    var lastError: String?
    /// 회사 관리자의 승인이 필요하다는 오류였다 (로그인 화면에 관리자 승인 링크를 보인다)
    private(set) var needsAdminConsent = false

    @ObservationIgnored private var tokens: TokenSet?
    /// ASWebAuthenticationSession은 끝날 때까지 강하게 잡아 둬야 한다.
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    /// 동시에 여러 요청이 토큰을 갱신하지 않도록 하나만 돌린다.
    @ObservationIgnored private var refreshTask: Task<TokenSet, Error>?
    @ObservationIgnored private let isDemo: Bool
    /// 계정마다 다른 키체인 항목 (M23). 처음 계정(예전 버전에서 로그인한 계정)은 "primary".
    let accountKey: String
    private var keychainAccount: String { accountKey }

    /// `demoEmail`이 있으면 데모 모드: 로그인한 것으로 보고 네트워크를 쓰지 않는다.
    init(accountKey: String = "primary", demoEmail: String? = nil) {
        self.accountKey = accountKey
        isDemo = demoEmail != nil
        super.init()
        if let demoEmail {
            email = demoEmail
            displayName = L("데모 사용자")
            return
        }
        if let data = Keychain.load(account: keychainAccount),
           let t = try? JSONDecoder().decode(TokenSet.self, from: data) {
            tokens = t
            email = t.email
            displayName = t.name
        }
    }

    var isSignedIn: Bool { isDemo || email != nil }

    /// 앱에 들어 있는 Azure 앱 등록 번호 (멀티 테넌트, build.sh가 Config/azure-client-id.txt에서 넣는다).
    /// 사용자는 이 번호를 몰라도 된다. 설정 > 계정 > 고급에 다른 번호를 넣으면 그것을 쓴다.
    static var bundledClientID: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "FAKUKUAzureClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("__") ? "" : value
    }

    /// 직접 넣은 번호 (고급). 비어 있으면 앱의 번호.
    var clientIDOverride: String {
        (UserDefaults.standard.string(forKey: "azureClientID") ?? "").trimmingCharacters(in: .whitespaces)
    }
    var clientID: String { clientIDOverride.isEmpty ? Self.bundledClientID : clientIDOverride }
    /// 비어 있으면 common: 어느 회사 계정(과 개인 Microsoft 계정)으로든 로그인한다.
    var tenant: String { (UserDefaults.standard.string(forKey: "azureTenant") ?? "").trimmingCharacters(in: .whitespaces) }
    /// 회사 관리자에게 보낼 승인 링크
    var adminConsentURL: URL? { OAuth.adminConsentURL(tenant: tenant, clientID: clientID, redirectURI: redirectURI) }
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "com.fakukulab.fakukumail" }
    var redirectURI: String { OAuth.redirectURI(bundleID: bundleID) }

    // MARK: 로그인

    /// `email`을 주면 Microsoft 로그인 창에 그 주소를 채운다 (비밀번호와 다중 인증은 그 창에서).
    func signIn(email: String? = nil) async {
        guard !isDemo, !isSigningIn else { return }
        lastError = nil
        needsAdminConsent = false
        guard !clientID.isEmpty else {
            lastError = L("이 빌드에는 Azure 앱 등록 번호가 없습니다. 설정 > 계정 > 고급에 클라이언트 ID를 넣거나, Config/azure-client-id.txt를 채워 다시 빌드하세요.")
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }

        let verifier = OAuth.randomVerifier()
        let state = OAuth.randomState()
        guard let url = OAuth.authorizeURL(tenant: tenant, clientID: clientID, redirectURI: redirectURI,
                                           challenge: OAuth.challenge(for: verifier), state: state, loginHint: email) else {
            lastError = L("로그인 주소를 만들 수 없습니다. 테넌트 값을 확인하세요.")
            return
        }
        do {
            let callback = try await webAuthenticate(url: url)
            switch OAuth.code(from: callback, expectedState: state) {
            case .failure(let error): throw error
            case .success(let code): try await exchange(code: code, verifier: verifier)
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // 사용자가 창을 닫음
        } catch {
            lastError = error.localizedDescription
            needsAdminConsent = OAuth.needsAdminConsent(error.localizedDescription)
        }
    }

    private func webAuthenticate(url: URL) async throws -> URL {
        let scheme = OAuth.redirectScheme(bundleID: bundleID)
        return try await withCheckedThrowingContinuation { continuation in
            // @Sendable: 이 콜백이 메인 스레드가 아닌 곳에서 불려도 Swift 6 런타임이 멈추지 않게.
            let s = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { @Sendable callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? URLError(.cancelled))
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() {
                session = nil
                continuation.resume(throwing: URLError(.cannotConnectToHost))
            }
        }
    }

    func signOut() {
        guard !isDemo else { return }
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        email = nil
        displayName = nil
        Keychain.delete(account: keychainAccount)
    }

    // MARK: 토큰

    func validAccessToken() async throws -> String {
        guard let current = tokens else { throw AuthError.signedOut }
        if current.expiresAt.timeIntervalSinceNow > 120 { return current.accessToken }
        if let running = refreshTask { return try await running.value.accessToken }

        let task = Task { try await self.refreshed(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value.accessToken
        } catch AuthError.expired {
            signOut()
            lastError = AuthError.expired.localizedDescription
            throw AuthError.expired
        }
    }

    private func refreshed(_ current: TokenSet) async throws -> TokenSet {
        // 로그인할 때의 번호·테넌트로 갱신한다 (그 뒤에 설정을 바꿔도 로그인이 풀리지 않게).
        let r = try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": current.refreshToken,
            "client_id": current.clientID ?? clientID, "scope": OAuth.scopes,
        ], tenant: current.tenant ?? tenant)
        var t = current
        t.accessToken = r.access_token
        t.refreshToken = r.refresh_token ?? current.refreshToken
        t.expiresAt = Date().addingTimeInterval(TimeInterval(r.expires_in))
        store(t)
        return t
    }

    private func exchange(code: String, verifier: String) async throws {
        let r = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": redirectURI, "code_verifier": verifier, "scope": OAuth.scopes,
        ], tenant: tenant)
        // 이메일은 /me로 확인한다.
        guard let meURL = URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName,displayName") else { return }
        var req = URLRequest(url: meURL)
        req.setValue("Bearer \(r.access_token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let me = try JSONDecoder().decode(GraphMe.self, from: data)
        store(TokenSet(accessToken: r.access_token, refreshToken: r.refresh_token ?? "",
                       expiresAt: Date().addingTimeInterval(TimeInterval(r.expires_in)),
                       email: me.mail ?? me.userPrincipalName ?? "", name: me.displayName,
                       clientID: clientID, tenant: tenant))
    }

    private func store(_ t: TokenSet) {
        tokens = t
        email = t.email
        displayName = t.name
        if let data = try? JSONEncoder().encode(t) { Keychain.save(data, account: keychainAccount) }
    }

    private struct GraphMe: Decodable {
        let mail: String?
        let userPrincipalName: String?
        let displayName: String?
    }

    private func tokenRequest(_ form: [String: String], tenant: String) async throws -> TokenResponse {
        guard let url = URL(string: "\(OAuth.authority(tenant: tenant))/token") else { throw AuthError.signedOut }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = OAuth.formBody(form)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if let e = try? JSONDecoder().decode(TokenErrorResponse.self, from: data) {
                if e.needsSignIn && form["grant_type"] == "refresh_token" { throw AuthError.expired }
                throw AuthError.server(e.error_description ?? e.error)
            }
            throw AuthError.server(String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

}

// The macOS 26 SDK marks this protocol @MainActor, so the main-actor method is the witness.
extension GraphAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}

enum AuthError: Error, LocalizedError {
    case signedOut
    case expired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: L("로그인이 필요합니다.")
        case .expired: L("로그인이 만료되었습니다. 다시 로그인하세요.")
        case .server(let message): L("Microsoft 로그인 오류: \(message)")
        }
    }
}
