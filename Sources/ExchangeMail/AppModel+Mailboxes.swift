import ExchangeMailKit
import Foundation

/// VIP (S-045)와 스마트 메일상자 (S-046): 사이드바의 서버 폴더가 아닌 상자.
extension AppModel {

    /// 지금 고른 상자가 서버 폴더가 아니면 그 종류
    var selectedVirtual: VirtualMailbox? { selectedFolderID.flatMap { VirtualMailbox(id: $0) } }

    /// 목록 제목
    var listTitle: String {
        switch selectedVirtual {
        case .flagged: "깃발 표시"
        case .flagColor(let c): "\(c.label) 깃발"
        case .allVIPs: "VIP"
        case .vip(let address): mailboxes.vip(address: address)?.title ?? address
        case .smart(let id): mailboxes.smart.first { $0.id == id }?.name ?? "스마트 메일상자"
        case nil: selectedFolder?.displayName ?? "메일"
        }
    }

    /// 서버 폴더가 아닌 상자의 메일
    func loadVirtual(_ box: VirtualMailbox) async throws -> MessagePage {
        switch box {
        case .flagged:
            return try await service.flaggedMessages()
        case .flagColor(let color):
            let page = try await service.flaggedMessages()
            return MessagePage(messages: page.messages.filter { flagColor(for: $0) == color }, nextLink: nil, serverFiltered: false)
        case .vip(let address):
            return try await service.messages(fromSender: address)
        case .allVIPs:
            var all: [MailMessage] = []
            for vip in mailboxes.vips {
                all += try await service.messages(fromSender: vip.address).messages
            }
            let sorted = all.sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
            return MessagePage(messages: sorted, nextLink: nil, serverFiltered: false)
        case .smart(let id):
            guard let smart = mailboxes.smart.first(where: { $0.id == id }) else {
                return MessagePage(messages: [], nextLink: nil, serverFiltered: false)
            }
            let page = try await service.collectMessages(folderID: smart.serverFolderID, filter: smart.graphFilter())
            // 폴더를 고르지 않았으면 지운 편지함과 정크 메일은 뺀다 (맥 Mail과 같다).
            let skipped = smart.usable.contains { $0.field == .folder } ? Set<String>() : skippedFolderIDs
            let vips = mailboxes.vipAddresses
            let kept = page.messages.filter { m in
                !(m.parentFolderId.map { skipped.contains($0) } ?? false) && smart.matches(m, vips: vips)
            }
            return MessagePage(messages: kept, nextLink: nil, serverFiltered: false)
        }
    }

    /// 지운 편지함과 정크 메일 폴더의 id
    var skippedFolderIDs: Set<String> {
        Set(folders.filter { ["deleteditems", "junkemail"].contains($0.kind ?? "") }.map(\.id)
            + ["deleteditems", "junkemail"])
    }

    // MARK: VIP

    /// 보낸 사람을 VIP 편집기에 연다 (새로 지정하거나 이름·아이콘을 바꾼다).
    func editVIP(for m: MailMessage) {
        guard let address = m.from?.emailAddress.address, !address.isEmpty else { return }
        editingVIP = mailboxes.vip(address: address) ?? VIP(address: address, name: m.from?.emailAddress.name ?? "")
    }

    /// 주소 하나로 VIP 편집기를 연다 (머리글 주소 메뉴)
    func editVIP(address: String, name: String?) {
        editingVIP = mailboxes.vip(address: address) ?? VIP(address: address, name: name ?? "")
    }

    func saveVIP(_ vip: VIP) {
        mailboxes.save(vip)
        editingVIP = nil
        updateMenu()
        if selectedVirtual == .allVIPs { Task { await loadMessages(keepSelection: true) } }
    }

    func removeVIP(address: String) {
        mailboxes.removeVIP(address: address)
        updateMenu()
        if selectedVirtual == .vip(address: address.lowercased()) {
            selectedFolderID = "inbox"
        } else if selectedVirtual == .allVIPs {
            Task { await loadMessages(keepSelection: true) }
        }
    }

    // MARK: 스마트 메일상자

    func newSmartMailbox() {
        editingSmart = SmartMailbox(name: "", conditions: [.init(field: .unread)])
    }

    func saveSmart(_ box: SmartMailbox) {
        mailboxes.save(box)
        editingSmart = nil
        if selectedFolderID == box.id {
            Task { await loadMessages(keepSelection: true) }
        } else {
            selectedFolderID = box.id
        }
    }

    func removeSmart(id: String) {
        mailboxes.removeSmart(id: id)
        if selectedFolderID == id { selectedFolderID = "inbox" }
    }
}
