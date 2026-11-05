import ExchangeMailKit
import Foundation
import Observation

// M23 계정 여러 개. 계정마다 로그인(GraphAuth, 키체인 항목이 따로)과 메일 서비스(오프라인 캐시 포함)가 있다.
// 계정 목록(키체인 항목 이름)은 UserDefaults "accounts.ids"에. 예전 버전의 계정은 "primary".

/// 계정 하나
final class MailAccount: Identifiable {
    let id: String
    let auth: GraphAuth
    let service: CachedMailService

    init(id: String, auth: GraphAuth, service: CachedMailService) {
        self.id = id
        self.auth = auth
        self.service = service
    }

    var email: String { auth.email ?? "" }
    var title: String { auth.displayName.map { "\($0) — \(email)" } ?? email }
}

@Observable
final class AccountStore {
    private(set) var accounts: [MailAccount] = []
    /// 사이드바에서 고른 폴더의 계정. 보내기·규칙·자동 응답은 이 계정에.
    var activeID: String?
    /// 새 계정을 더할 때 쓰는 로그인 (계정이 하나도 없으면 로그인 화면이 이것을 쓴다)
    private(set) var pending: GraphAuth

    /// 계정마다 설명 (설정 > 계정 > 설명). 사이드바 구역 이름에 쓴다. 비어 있으면 이메일 주소.
    private(set) var descriptions: [String: String] =
        UserDefaults.standard.dictionary(forKey: "accounts.descriptions") as? [String: String] ?? [:]

    @ObservationIgnored private let makeService: (GraphAuth) -> CachedMailService
    @ObservationIgnored private let persist: Bool
    private static let idsKey = "accounts.ids"

    var active: MailAccount? { accounts.first { $0.id == activeID } ?? accounts.first }

    /// `demoEmail`이 있으면 데모 계정 하나 (스냅숏, 셀프 테스트)
    init(demoEmail: String?, makeService: @escaping (GraphAuth) -> CachedMailService) {
        self.makeService = makeService
        persist = demoEmail == nil && !Store.isOverridden
        if let demoEmail {
            let auth = GraphAuth(accountKey: "demo", demoEmail: demoEmail)
            pending = auth
            accounts = [MailAccount(id: "demo", auth: auth, service: makeService(auth))]
        } else {
            pending = GraphAuth(accountKey: UUID().uuidString)
            var ids = UserDefaults.standard.stringArray(forKey: Self.idsKey) ?? []
            if ids.isEmpty { ids = ["primary"] }   // 예전 버전: 키체인 "primary"에 계정 하나
            for id in ids {
                let auth = GraphAuth(accountKey: id)
                if auth.isSignedIn { accounts.append(MailAccount(id: id, auth: auth, service: makeService(auth))) }
            }
        }
        activeID = accounts.first?.id
    }

    /// 계정 추가: Microsoft 로그인 창으로 로그인하고, 성공하면 목록에 넣는다.
    /// 이미 있는 주소면 넣지 않는다 (그 로그인은 지운다). 더한 계정을 돌려준다.
    @discardableResult
    func addAccount(email: String?) async -> MailAccount? {
        let auth = pending
        await auth.signIn(email: email)
        guard auth.isSignedIn, let address = auth.email?.lowercased(), !address.isEmpty else { return nil }
        if accounts.contains(where: { $0.email.lowercased() == address }) {
            auth.signOut()
            pending = GraphAuth(accountKey: UUID().uuidString)
            pending.lastError = L("이미 추가한 계정입니다: \(address)")
            return nil
        }
        let account = MailAccount(id: auth.accountKey, auth: auth, service: makeService(auth))
        accounts.append(account)
        if activeID == nil { activeID = account.id }
        pending = GraphAuth(accountKey: UUID().uuidString)
        save()
        return account
    }

    /// 계정 빼기: 이 Mac에 저장한 그 계정의 메일과 로그인을 지운다 (서버의 메일은 그대로).
    func remove(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        account.service.clearCache()
        account.auth.signOut()
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = accounts.first?.id }
        save()
    }

    /// 사이드바·설정에 보일 계정 이름
    func title(for account: MailAccount) -> String {
        let d = descriptions[account.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return d.isEmpty ? (account.email.isEmpty ? L("메일상자") : account.email) : d
    }

    func setDescription(_ text: String, for id: String) {
        descriptions[id] = text
        if persist { UserDefaults.standard.set(descriptions, forKey: "accounts.descriptions") }
    }

    private func save() {
        guard persist else { return }
        UserDefaults.standard.set(accounts.map(\.id), forKey: Self.idsKey)
    }
}
