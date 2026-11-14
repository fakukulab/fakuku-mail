import ExchangeMailKit
import Foundation

/// 메시지 > 규칙 만들기가 설정 > 규칙에 넘기는 시작 값 (S-075)
struct RuleSeed: Equatable {
    var form: RuleForm
    var accountID: String?
}

/// 규칙을 지금 실행한 결과
struct RuleRunReport: Equatable {
    var scanned = 0
    var applied = 0
    var failed = 0
    /// 전달·리디렉션 동작은 지금 실행에서 하지 않았다
    var skippedSending = false
    /// 살펴볼 수 있는 수를 넘어 멈췄다
    var stoppedAtLimit = false
}

enum RuleRunError: LocalizedError {
    case unsupported([RuleConditionKind])

    var errorDescription: String? {
        switch self {
        case .unsupported(let kinds):
            L("다음 조건은 Exchange 서버만 판단할 수 있어 지금 실행할 수 없습니다: \(kinds.map(\.title).joined(separator: ", ")). 새로 오는 메일에는 그대로 적용됩니다.")
        }
    }
}

/// Outlook과 같은 받은 편지함 규칙 (S-039, S-075): 조건·동작·예외를 고치고, 차례를 바꾸고, 이미 받은 메일에 지금 실행한다.
/// 규칙은 Exchange 서버에 있어 앱이 꺼져 있어도 새 메일에 적용되고 Outlook에도 보인다.
extension AppModel {
    /// 지금 실행이 한 번에 살펴보는 메일 수
    static let ruleRunLimit = 5000

    /// 이 계정의 규칙 (서버 차례대로). 차단된 보낸 사람 규칙은 뺀다: 설정 > 정크 메일 > 차단됨이 관리한다.
    func rules(of account: MailAccount) async throws -> [MessageRule] {
        try await account.service.rules()
            .filter { !BlockedSenders.isBlockRule($0) }
            .sorted { ($0.sequence ?? .max) < ($1.sequence ?? .max) }
    }

    /// 규칙을 둘 계정: 고른 계정, 지금 계정, 첫 Exchange 계정 차례
    func ruleAccount(_ id: String?) -> MailAccount? {
        exchangeAccounts.first { $0.id == id }
            ?? exchangeAccounts.first { $0.id == accounts.active?.id }
            ?? exchangeAccounts.first
    }

    /// 계정의 폴더 (규칙의 폴더 고르기)
    func ruleFolders(of account: MailAccount) -> [MailFolder] {
        accountFolders[account.id] ?? (account.id == accounts.active?.id ? folders : [])
    }

    /// 새 규칙은 맨 끝에. 고친 규칙은 같은 차례·켜짐으로: 이름만 바꿨으면 이름만 고치고,
    /// 조건·동작이 바뀌었으면 새로 만든 뒤 옛것을 지운다 (Graph가 고친 조건을 합쳐 버리지 않게).
    func saveRule(_ form: RuleForm, replacing old: MessageRule?, in account: MailAccount,
                  existing: [MessageRule]) async throws -> MessageRule {
        let service = account.service
        guard let old else {
            let next = (existing.compactMap(\.sequence).max() ?? 0) + 1
            return try await service.createRule(form.rule(sequence: next))
        }
        var made = form.rule(sequence: old.sequence ?? 1)
        made.isEnabled = old.isEnabled ?? true
        let sameContent = (made.conditions ?? .init()).cleaned == (old.conditions ?? .init()).cleaned
            && (made.exceptions ?? .init()).cleaned == (old.exceptions ?? .init()).cleaned
            && (made.actions ?? .init()).cleaned == (old.actions ?? .init()).cleaned
        if sameContent {
            if made.displayName != old.displayName {
                try await service.updateRule(id: old.id, displayName: made.displayName, sequence: nil)
            }
            made.id = old.id
            return made
        }
        let created = try await service.createRule(made)
        try await service.deleteRule(id: old.id)
        return created
    }

    /// 규칙을 한 칸 위(-1)나 아래(+1)로. 차례를 1부터 다시 매겨 서버에 바뀐 것만 적는다.
    func moveRule(_ rule: MessageRule, by offset: Int, in list: [MessageRule], account: MailAccount) async throws -> [MessageRule] {
        var order = list
        guard let i = order.firstIndex(where: { $0.id == rule.id }) else { return list }
        let j = i + offset
        guard order.indices.contains(j) else { return list }
        order.swapAt(i, j)
        for (n, r) in order.enumerated() where r.sequence != n + 1 {
            try await account.service.updateRule(id: r.id, displayName: nil, sequence: n + 1)
            order[n].sequence = n + 1
        }
        return order
    }

    /// 지금 실행: 고른 폴더의 메일에 이 규칙을 이 Mac에서 적용한다 (Outlook의 "지금 규칙 실행").
    /// 전달·리디렉션은 하지 않는다: 예전 메일을 한꺼번에 남에게 보내지 않게.
    func runRuleNow(_ rule: MessageRule, account: MailAccount, folderID: String,
                    progress: @escaping (String) -> Void) async throws -> RuleRunReport {
        let unsupported = RuleMatcher.unsupported(rule)
        guard unsupported.isEmpty else { throw RuleRunError.unsupported(unsupported) }
        let service = account.service
        let me = [account.auth.email].compactMap { $0 }
        let detail = RuleMatcher.needsDetail(rule)
        var report = RuleRunReport()
        var hits: [MailMessage] = []

        var page = try await service.messages(folderID: folderID, search: nil)
        while true {
            for m in page.messages where PendingDrafts.id(fromMessageID: m.id) == nil {
                report.scanned += 1
                guard RuleMatcher.matches(rule, message: m, me: me, ignoringDetail: true) else { continue }
                var full = m
                if detail {
                    guard let d = try? await service.message(id: m.id) else {
                        report.failed += 1
                        continue
                    }
                    full.body = d.body
                    full.internetMessageHeaders = d.internetMessageHeaders
                }
                if RuleMatcher.matches(rule, message: full, me: me) { hits.append(full) }
            }
            progress(L("메일 \(report.scanned)통을 살펴보는 중…"))
            guard let next = page.nextLink else { break }
            guard report.scanned < Self.ruleRunLimit else {
                report.stoppedAtLimit = true
                break
            }
            page = try await service.nextPage(next)
        }

        let a = (rule.actions ?? .init()).cleaned
        report.skippedSending = a.forwardTo != nil || a.forwardAsAttachmentTo != nil || a.redirectTo != nil
        for (n, m) in hits.enumerated() {
            progress(L("규칙을 적용하는 중… \(n + 1)/\(hits.count)"))
            do {
                if let add = a.assignCategories {
                    let now = m.categories ?? []
                    let more = add.filter { c in !now.contains { $0.caseInsensitiveCompare(c) == .orderedSame } }
                    if !more.isEmpty { try await service.setCategories(id: m.id, categories: now + more) }
                }
                if let i = a.markImportance, (m.importance ?? "normal") != i {
                    try await service.setImportance(id: m.id, importance: i)
                }
                if a.markAsRead == true, m.isUnread { try await service.setRead(id: m.id, read: true) }
                if let f = a.copyToFolder { try await service.copy(id: m.id, to: f) }
                if a.permanentDelete == true {
                    try await service.deleteMessage(id: m.id)
                } else if a.delete == true {
                    _ = try await service.move(id: m.id, to: "deleteditems")
                } else if let f = a.moveToFolder, f != folderID {
                    _ = try await service.move(id: m.id, to: f)
                }
                report.applied += 1
            } catch {
                report.failed += 1
            }
        }
        if !hits.isEmpty {
            threadCache = [:]   // 대화가 바뀌었다 (AppModel+Prefetch)
            await refresh()
        }
        return report
    }

    /// 메시지 > 규칙 만들기: 보낸 사람 조건으로 시작하는 규칙 편집 창을 설정 > 규칙에서 연다.
    func seedRule(from message: MailMessage) {
        ruleSeed = RuleSeed(form: .seed(from: message), accountID: router.accountID(forMessage: message.id))
        settingsTab = .rules
    }
}
