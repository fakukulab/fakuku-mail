import ExchangeMailKit
import Foundation

/// 차단된 보낸 사람 (설정 > 정크 메일 > 차단됨, 1.0.6).
/// - 목록은 앱이 이 Mac에 보관한다 (`BlockList`, UserDefaults "blocked.list").
/// - Exchange 계정: 같은 목록을 받은 편지함 서버 규칙(`BlockedSenders`)에도 넣는다. 앱이 꺼져 있어도 서버가 거른다.
/// - iCloud·Gmail(IMAP) 계정: 서버 규칙이 없어 앱이 거른다. 새 메일을 확인할 때와 받은 편지함을 열 때
///   "지운 편지함으로 이동"이면 옮기고, "표시만"이면 목록에 차단 표시를 붙인다.
/// - 예전 버전(서버 규칙에만 저장)의 목록은 처음 한 번 가져온다.
extension AppModel {

    private static let blockListKey = "blocked.list"
    private static let blockAdoptedKey = "blocked.adoptedServerRule"

    static func savedBlockList() -> BlockList {
        guard !Store.isOverridden, let data = UserDefaults.standard.data(forKey: blockListKey),
              let list = try? JSONDecoder().decode(BlockList.self, from: data) else { return BlockList() }
        return list
    }

    func saveBlockList() {
        guard !Store.isOverridden, let data = try? JSONEncoder().encode(blockList) else { return }
        UserDefaults.standard.set(data, forKey: Self.blockListKey)
    }

    var blockedAddresses: [String] { blockList.addresses }
    var blockMode: BlockedSenders.Mode { blockList.mode }
    var blockEnabled: Bool { blockList.enabled }

    /// 서버 규칙을 함께 두는 계정 (Microsoft Exchange)
    var exchangeAccounts: [MailAccount] { accounts.accounts.filter { $0.imap == nil } }
    /// 첫 Exchange 계정의 차단 규칙 (셀프 테스트와 안내 글)
    var blockedRule: MessageRule? { exchangeAccounts.first.flatMap { blockedRules[$0.id] } }

    /// Exchange 계정마다 서버 규칙을 읽고, 처음이면 예전 목록을 가져오고, 앱 목록과 다르면 서버를 맞춘다.
    func loadBlocked() async {
        for a in exchangeAccounts {
            do {
                blockedRules[a.id] = try await a.service.rules().first(where: BlockedSenders.isBlockRule)
                blockRuleKnown.insert(a.id)
            } catch {
                blockRuleKnown.remove(a.id)
                report(error)
            }
        }
        if !blockAdopted, exchangeAccounts.allSatisfy({ blockRuleKnown.contains($0.id) }) {
            var list = blockList
            for a in exchangeAccounts { list.adopt(blockedRules[a.id]) }
            blockList = list
            blockAdopted = true
        }
        blockedLoaded = true
        await syncBlockRules()
    }

    /// 예전 서버 규칙을 앱 목록으로 가져왔는가 (한 번만). 테스트 실행은 메모리에만.
    private var blockAdopted: Bool {
        get { Store.isOverridden ? blockAdoptedInMemory : UserDefaults.standard.bool(forKey: Self.blockAdoptedKey) }
        set {
            if Store.isOverridden {
                blockAdoptedInMemory = newValue
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.blockAdoptedKey)
            }
        }
    }

    /// 앱 목록을 Exchange 서버 규칙에 옮긴다. 규칙을 읽은 계정만 (읽지 못한 계정은 다음에 다시 읽고 맞춘다).
    /// Graph 규칙은 조건을 고치기보다 새로 만드는 편이 확실하다. 목록이 비면 규칙을 지운다.
    func syncBlockRules() async {
        for a in exchangeAccounts where blockRuleKnown.contains(a.id) {
            let old = blockedRules[a.id]
            guard !blockList.sameAsRule(old) else { continue }
            let list = blockList
            do {
                if let old {
                    try await a.service.deleteRule(id: old.id)
                    blockedRules[a.id] = nil
                }
                guard !list.addresses.isEmpty else { continue }
                var made = try await a.service.createRule(
                    BlockedSenders.rule(addresses: list.addresses, mode: list.mode, enabled: true))
                if !list.enabled {
                    try await a.service.setRule(id: made.id, enabled: false)
                    made.isEnabled = false
                }
                blockedRules[a.id] = made
            } catch {
                // 앱 목록은 저장돼 있다. 다음 새 메일 확인 때 규칙을 다시 읽고 맞춘다.
                blockRuleKnown.remove(a.id)
                report(error)
            }
        }
    }

    /// 새 메일 확인 때: 아직 규칙을 읽지 못한 Exchange 계정이 있으면 읽고 맞춘다 (앱을 켠 직후, 오프라인이었을 때).
    func syncBlockRulesIfNeeded() async {
        guard exchangeAccounts.contains(where: { !blockRuleKnown.contains($0.id) }) else { return }
        await loadBlocked()
    }

    /// 목록을 바꾸고 저장하고 서버 규칙과 받은 편지함에 적용한다.
    func changeBlockList(_ change: (inout BlockList) -> Void) async {
        var list = blockList
        change(&list)
        guard list != blockList else { return }
        blockList = list
        await syncBlockRules()
        await sweepVisibleBlocked()
    }

    func saveBlocked(addresses: [String], mode: BlockedSenders.Mode, enabled: Bool) async {
        await changeBlockList { $0 = BlockList(addresses: addresses, enabled: enabled, mode: mode) }
    }

    func block(address: String) async {
        await changeBlockList { $0.add(address) }
    }

    func unblock(address: String) async {
        await unblock(addresses: [address])
    }

    /// 주소 항목을 뺀다. 도메인 항목(@example.com)에 걸린 주소면 그 도메인 항목도 뺀다.
    func unblock(addresses: [String]) async {
        await changeBlockList { list in
            let lowered = addresses.map { $0.lowercased() }
            let domains = list.addresses.filter { entry in
                BlockList.isDomain(entry) && lowered.contains { BlockList(addresses: [entry]).matches($0) }
            }
            list.remove(lowered + domains)
        }
    }

    /// 메시지 > 보낸 사람 차단: 목록에 넣고, 지운 편지함으로 옮기는 방식이면 이 메일도 옮긴다.
    func blockSender(of m: MailMessage, undoManager: UndoManager?) async {
        guard let address = m.from?.emailAddress.address, !address.isEmpty else { return }
        await changeBlockList { $0.add(address) }
        if blockEnabled, blockMode == .trash, messages.contains(where: { $0.id == m.id }) {
            await move([m.id], to: "deleteditems", undoManager: undoManager, undoName: L("보낸 사람 차단"))
        }
    }

    /// 목록 줄의 차단 표시: 걸러내기가 켜져 있고 보낸 사람이 목록에 있다.
    func isBlocked(_ m: MailMessage) -> Bool { blockList.blocks(m.from?.emailAddress.address) }

    // MARK: 앱이 거르는 계정 (iCloud·Gmail)

    /// 이 계정의 받은 편지함 메일 중 차단된 보낸 사람의 것을 지운 편지함으로 옮긴다. 옮긴 메일 id.
    /// Exchange는 서버 규칙이 거르므로 건드리지 않는다.
    @discardableResult
    func sweepBlocked(_ inbox: [MailMessage], account: MailAccount) async -> Set<String> {
        guard account.imap != nil else { return [] }
        var moved = Set<String>()
        for m in blockList.toTrash(inbox) {
            do {
                _ = try await account.service.move(id: m.id, to: "deleteditems")
                moved.insert(m.id)
            } catch {
                report(error)
            }
        }
        if !moved.isEmpty {
            messages.removeAll { moved.contains($0.id) }
            selection.subtract(moved)
            if let id = selectedMessageID, moved.contains(id) { selectedMessageID = nil }
            threadCache = [:]
        }
        return moved
    }

    /// 지금 목록에 보이는 iCloud·Gmail 받은 편지함 메일에 적용한다 (받은 편지함을 열 때, 목록·방식을 바꿀 때).
    func sweepVisibleBlocked() async {
        guard blockList.enabled, blockList.mode == .trash, !blockList.addresses.isEmpty else { return }
        var any = false
        for a in accounts.accounts where a.imap != nil {
            guard let inbox = accountFolders[a.id]?.first(where: { $0.kind == "inbox" })?.id else { continue }
            let list = messages.filter { $0.parentFolderId == inbox }
            if !(await sweepBlocked(list, account: a)).isEmpty { any = true }
        }
        if any { await loadFolders() }
    }
}
