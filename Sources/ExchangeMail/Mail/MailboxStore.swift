import ExchangeMailKit
import Foundation
import Observation

/// VIP와 스마트 메일상자 (S-045, S-046). 이 Mac의 `mailboxes.json`에 둔다. 로그아웃해도 남는다.
@Observable
final class MailboxStore {
    private let url: URL
    private(set) var vips: [VIP] = []
    private(set) var smart: [SmartMailbox] = []
    /// 즐겨찾기 (S-073): 서버 폴더 id
    private(set) var favorites: [String] = []

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(LocalMailboxes.self, from: data) {
            vips = saved.vips
            smart = saved.smart
            favorites = saved.favorites
        }
    }

    /// 보낸 사람이 VIP면 그 사람
    func vip(for m: MailMessage) -> VIP? {
        guard let address = m.from?.emailAddress.address?.lowercased() else { return nil }
        return vips.first { $0.id == address }
    }

    func vip(address: String) -> VIP? { vips.first { $0.id == address.lowercased() } }

    var vipAddresses: Set<String> { Set(vips.map(\.id)) }

    /// 넣거나 바꾼다 (주소로 알아본다). 이름순으로 둔다.
    func save(_ vip: VIP) {
        vips.removeAll { $0.id == vip.id }
        vips.append(vip)
        vips.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        write()
    }

    func removeVIP(address: String) {
        vips.removeAll { $0.id == address.lowercased() }
        write()
    }

    func save(_ box: SmartMailbox) {
        if let i = smart.firstIndex(where: { $0.id == box.id }) { smart[i] = box } else { smart.append(box) }
        write()
    }

    func removeSmart(id: String) {
        smart.removeAll { $0.id == id }
        write()
    }

    func isFavorite(_ folderID: String) -> Bool { favorites.contains(folderID) }

    func addFavorite(_ folderID: String) {
        guard !favorites.contains(folderID) else { return }
        favorites.append(folderID)
        write()
    }

    func removeFavorite(_ folderID: String) {
        favorites.removeAll { $0 == folderID }
        write()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(LocalMailboxes(vips: vips, smart: smart, favorites: favorites)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
