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
    /// 목록에서 고른 메일
    var selection: ArchivedMail.ID?

    @ObservationIgnored let directory: URL
    private var indexURL: URL { directory.appending(path: "index.json") }

    /// 한 번 읽은 상자는 기억한다: 다른 상자를 갔다 와도 파일을 다시 읽지 않는다 (최근 4개).
    private struct Loaded {
        var mails: [ArchivedMail]
        /// 메일 id → 검색용 글 (MailArchive.searchText)
        var search: [Int: String]
        var selection: ArchivedMail.ID?
    }
    @ObservationIgnored private var loaded: [String: Loaded] = [:]
    @ObservationIgnored private var recent: [String] = []
    @ObservationIgnored private var search: [Int: String] = [:]

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appending(path: "index.json")) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            boxes = (try? decoder.decode([LocalMailbox].self, from: data)) ?? []
        }
    }

    func fileURL(_ box: LocalMailbox) -> URL { directory.appending(path: box.fileName) }

    /// 검색: 메인 창 도구 막대의 검색 칸 글로 거른다. 제목·사람·본문·첨부 이름, 낱말이 모두 들어 있어야.
    func filtered(_ query: String) -> [ArchivedMail] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return mails }
        return mails.filter { MailArchive.matches(search[$0.id] ?? MailArchive.searchText($0), query: q) }
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

    /// 상자의 메일을 읽는다. 이미 열려 있거나 전에 읽었으면 파일을 다시 읽지 않는다.
    func open(_ id: String) async {
        if openedID == id && failure == nil && !mails.isEmpty { return }
        guard let box = boxes.first(where: { $0.id == id }) else { return }
        // 지금 상자의 고른 메일을 기억해 둔다.
        if let current = openedID { loaded[current]?.selection = selection }
        openedID = id
        failure = nil
        if let cached = loaded[id] {
            mails = cached.mails
            search = cached.search
            selection = cached.selection ?? cached.mails.first?.id
            touch(id)
            return
        }
        mails = []
        search = [:]
        selection = nil
        isLoading = true
        defer { isLoading = false }
        let url = fileURL(box)
        do {
            let (list, index) = try await Task.detached(priority: .userInitiated) { () throws -> ([ArchivedMail], [Int: String]) in
                let list = try ArchiveFile.load(url)
                return (list, Dictionary(uniqueKeysWithValues: list.map { ($0.id, MailArchive.searchText($0)) }))
            }.value
            loaded[id] = Loaded(mails: list, search: index, selection: list.first?.id)
            touch(id)
            guard openedID == id else { return }
            mails = list
            search = index
            selection = list.first?.id
        } catch {
            failure = error.localizedDescription
        }
    }

    private func touch(_ id: String) {
        recent.removeAll { $0 == id }
        recent.append(id)
        while recent.count > 4 { loaded[recent.removeFirst()] = nil }
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
        loaded[id] = nil
        recent.removeAll { $0 == id }
        if openedID == id { openedID = nil; mails = []; search = [:]; selection = nil }
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
