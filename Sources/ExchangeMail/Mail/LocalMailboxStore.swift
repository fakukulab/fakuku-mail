import ExchangeMailKit
import Foundation
import Observation

// S-055 나의 Mac에: 가져온 메일상자를 앱 안에 보관한다.
// 파일은 Store.directory/local/<id>.mbox (가져올 때 표준 mbox로 다시 쓴다), 목록은 local/index.json.
// 서버와 상관없다: 로그아웃해도 남고, 오프라인에서도 열린다.

nonisolated struct LocalMailbox: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var count: Int
    var added: Date

    var fileName: String { "\(id).mbox" }
    /// 사이드바 선택 값 (서버 폴더 id와 겹치지 않게 앞에 붙인다)
    var sidebarID: String { Self.prefix + id }

    static let prefix = "local:"
    static func id(fromSidebar value: String?) -> String? {
        guard let value, value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

@Observable
final class LocalMailboxStore {
    private(set) var boxes: [LocalMailbox] = []
    /// 지금 연 상자와 그 메일
    private(set) var openedID: String?
    private(set) var mails: [ArchivedMail] = []
    private(set) var isLoading = false
    private(set) var failure: String?
    /// 목록에서 고른 메일, 검색어
    var selection: ArchivedMail.ID?
    var searchText = ""

    @ObservationIgnored let directory: URL
    private var indexURL: URL { directory.appending(path: "index.json") }

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appending(path: "index.json")) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            boxes = (try? decoder.decode([LocalMailbox].self, from: data)) ?? []
        }
    }

    func fileURL(_ box: LocalMailbox) -> URL { directory.appending(path: box.fileName) }

    var filtered: [ArchivedMail] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return mails }
        return mails.filter {
            $0.subject.lowercased().contains(q) || $0.from.lowercased().contains(q) || $0.to.lowercased().contains(q)
                || ($0.text ?? "").lowercased().contains(q)
        }
    }

    var selectedMail: ArchivedMail? { mails.first { $0.id == selection } }

    // MARK: 가져오기

    /// 파일(.mbox, .eml, .emlx)이나 폴더의 메일을 앱 안에 mbox로 저장하고 목록에 넣는다.
    func importMailbox(from url: URL) async throws -> LocalMailbox {
        let id = UUID().uuidString
        let target = directory.appending(path: "\(id).mbox")
        let dir = directory
        let count = try await Task.detached(priority: .userInitiated) { () throws -> Int in
            let raw = try ArchiveFile.rawMessages(url)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var out = Data()
            for message in raw {
                out.append(MailArchive.mboxEntry(message, date: MailArchive.parse(message).date))
            }
            try out.write(to: target, options: .atomic)
            return raw.count
        }.value
        var name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = L("가져온 메일") }
        let taken = Set(boxes.map(\.name))
        if taken.contains(name) {
            var n = 2
            while taken.contains("\(name) \(n)") { n += 1 }
            name = "\(name) \(n)"
        }
        let box = LocalMailbox(id: id, name: name, count: count, added: Date())
        boxes.append(box)
        boxes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try save()
        return box
    }

    // MARK: 열기

    /// 상자의 메일을 읽는다 (이미 열려 있으면 그대로).
    func open(_ id: String) async {
        if openedID == id && failure == nil { return }
        guard let box = boxes.first(where: { $0.id == id }) else { return }
        openedID = id
        mails = []
        selection = nil
        searchText = ""
        failure = nil
        isLoading = true
        defer { isLoading = false }
        let url = fileURL(box)
        do {
            let list = try await Task.detached(priority: .userInitiated) { try ArchiveFile.load(url) }.value
            guard openedID == id else { return }
            mails = list
            selection = list.first?.id
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: 이름 바꾸기, 지우기

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[i].name = trimmed
        try? save()
    }

    func remove(_ id: String) {
        guard let box = boxes.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: fileURL(box))
        boxes.removeAll { $0.id == id }
        if openedID == id { openedID = nil; mails = []; selection = nil }
        try? save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(boxes).write(to: indexURL, options: .atomic)
    }
}
