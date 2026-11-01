import ExchangeMailKit
import Foundation
import Observation

/// 서명 여러 개와 상황별 기본 규칙. `<Store.directory>/signatures.json`에 바로 저장한다.
@Observable
final class SignatureStore {
    var signatures: [Signature] = [] { didSet { save() } }
    var rules = SignatureRules() { didSet { save() } }

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var loading = false

    private struct Payload: Codable {
        var signatures: [Signature]
        var rules: SignatureRules
    }

    init(url: URL) {
        self.url = url
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        loading = true
        signatures = payload.signatures
        rules = payload.rules
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Payload(signatures: signatures, rules: rules)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func signature(id: UUID?) -> Signature? {
        guard let id else { return nil }
        return signatures.first { $0.id == id }
    }

    func defaultSignature(kind: ComposeKind, account: String?) -> Signature? {
        signature(id: rules.signatureID(kind: kind, account: account))
    }

    @discardableResult
    func add(name: String? = nil) -> Signature {
        let s = Signature(name: name ?? nextName(),
                          html: "<div style=\"font-family:-apple-system,'Apple SD Gothic Neo';font-size:13px\">이름<br>회사 · 직함</div>")
        signatures.append(s)
        return s
    }

    private func nextName() -> String {
        let names = Set(signatures.map(\.name))
        var n = signatures.count + 1
        while names.contains("서명 \(n)") { n += 1 }
        return "서명 \(n)"
    }

    func delete(id: UUID) {
        signatures.removeAll { $0.id == id }
        rules.forget(id)
    }

    func update(id: UUID, name: String? = nil, html: String? = nil) {
        guard let i = signatures.firstIndex(where: { $0.id == id }) else { return }
        var s = signatures[i]
        if let name { s.name = name }
        if let html { s.html = html }
        guard s != signatures[i] else { return }
        s.updatedAt = Date()
        signatures[i] = s
    }

    /// 설정 화면의 "기본 서명" 고르기: nil은 "없음".
    func ruleSelection(_ kind: ComposeKind) -> UUID? {
        guard let id = rules.defaults[kind.ruleKind.rawValue], id != SignatureRules.noneID else { return nil }
        return signature(id: id)?.id
    }

    func setRule(_ kind: ComposeKind, to id: UUID?) {
        rules.defaults[kind.ruleKind.rawValue] = id ?? SignatureRules.noneID
    }

    /// 규칙 한 줄 (S-021). `account`가 nil이면 모든 계정. 지워진 서명을 가리키면 "없음"으로 보인다.
    func choice(_ kind: ComposeKind, account: String?) -> RuleChoice {
        let c = rules.choice(kind: kind, account: account)
        if case .signature(let id) = c, signature(id: id) == nil { return .none }
        return c
    }

    func setChoice(_ choice: RuleChoice, kind: ComposeKind, account: String?) {
        rules.setChoice(choice, kind: kind, account: account)
    }
}
