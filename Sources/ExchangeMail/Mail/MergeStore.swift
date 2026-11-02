import ExchangeMailKit
import Foundation
import Observation

/// 개별 발송 템플릿과 받는 사람 그룹 (M18). 이 Mac의 `merge.json`에 둔다.
@Observable
final class MergeStore {
    private let url: URL
    private(set) var library = MergeLibrary()

    init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode(MergeLibrary.self, from: data) {
            library = saved
        }
    }

    var templates: [MergeTemplate] { library.templates }
    var groups: [MergeGroup] { library.groups }

    func template(_ id: UUID?) -> MergeTemplate? { library.templates.first { $0.id == id } }
    func group(_ id: UUID?) -> MergeGroup? { library.groups.first { $0.id == id } }

    @discardableResult
    func addTemplate(name: String = L("새 템플릿")) -> MergeTemplate {
        let t = MergeTemplate(name: name, html: L("<div>{{이름}}님, 안녕하세요.</div><div><br></div>"))
        library.templates.append(t)
        write()
        return t
    }

    func save(_ t: MergeTemplate) {
        var t = t
        t.updatedAt = Date()
        if let i = library.templates.firstIndex(where: { $0.id == t.id }) { library.templates[i] = t } else { library.templates.append(t) }
        write()
    }

    func removeTemplate(_ id: UUID) {
        library.templates.removeAll { $0.id == id }
        write()
    }

    @discardableResult
    func addGroup(name: String = L("새 그룹")) -> MergeGroup {
        let g = MergeGroup(name: name)
        library.groups.append(g)
        write()
        return g
    }

    func save(_ g: MergeGroup) {
        if let i = library.groups.firstIndex(where: { $0.id == g.id }) { library.groups[i] = g } else { library.groups.append(g) }
        write()
    }

    func removeGroup(_ id: UUID) {
        library.groups.removeAll { $0.id == id }
        write()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(library) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
