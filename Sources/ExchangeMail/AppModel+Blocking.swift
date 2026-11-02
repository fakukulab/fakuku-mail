import ExchangeMailKit
import Foundation

/// 차단된 보낸 사람 (설정 > 정크 메일 > 차단됨). 받은 편지함 서버 규칙 하나(`BlockedSenders`)로 관리한다.
extension AppModel {

    var blockedAddresses: [String] { BlockedSenders.addresses(in: blockedRule) }
    var blockMode: BlockedSenders.Mode { BlockedSenders.mode(of: blockedRule) }
    var blockEnabled: Bool { blockedRule?.isEnabled ?? true }

    func loadBlocked() async {
        do {
            blockedRule = try await service.rules().first(where: BlockedSenders.isBlockRule)
            blockedLoaded = true
        } catch {
            report(error)
        }
    }

    /// 규칙을 다시 만든다 (Graph 규칙은 조건을 고치기보다 새로 만드는 편이 확실하다). 주소가 없으면 규칙을 지운다.
    func saveBlocked(addresses: [String], mode: BlockedSenders.Mode, enabled: Bool) async {
        do {
            if let old = blockedRule { try await service.deleteRule(id: old.id) }
            blockedRule = nil
            guard !addresses.isEmpty else { return }
            var made = try await service.createRule(BlockedSenders.rule(addresses: addresses, mode: mode, enabled: true))
            if !enabled {
                try await service.setRule(id: made.id, enabled: false)
                made.isEnabled = false
            }
            blockedRule = made
        } catch {
            report(error, quietIfOffline: false)
            await loadBlocked()
        }
    }

    func block(address: String) async {
        if !blockedLoaded { await loadBlocked() }
        guard !blockedAddresses.contains(where: { $0.lowercased() == address.lowercased() }) else { return }
        await saveBlocked(addresses: blockedAddresses + [address], mode: blockMode, enabled: blockEnabled)
    }

    func unblock(address: String) async {
        await saveBlocked(addresses: blockedAddresses.filter { $0.lowercased() != address.lowercased() },
                          mode: blockMode, enabled: blockEnabled)
    }

    /// 메시지 > 보낸 사람 차단: 규칙에 넣고, 지운 편지함으로 옮기는 방식이면 이 메일도 옮긴다.
    func blockSender(of m: MailMessage, undoManager: UndoManager?) async {
        guard let address = m.from?.emailAddress.address, !address.isEmpty else { return }
        await block(address: address)
        if blockMode == .trash, messages.contains(where: { $0.id == m.id }) {
            await move([m.id], to: "deleteditems", undoManager: undoManager, undoName: "보낸 사람 차단")
        }
    }

    func isBlocked(_ m: MailMessage) -> Bool {
        guard let a = m.from?.emailAddress.address?.lowercased() else { return false }
        return blockedAddresses.contains { $0.lowercased() == a }
    }
}
