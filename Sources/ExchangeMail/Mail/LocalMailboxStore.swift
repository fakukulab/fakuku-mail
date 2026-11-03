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

/// 모든 폴더 검색에서 찾은 나의 Mac에 메일 한 통
nonisolated struct LocalHit: Identifiable, Hashable, Sendable {
    let boxID: String
    let boxName: String
    let summary: ArchivedSummary
    var id: String { "\(boxID):\(summary.id)" }
}

@Observable
final class LocalMailboxStore {
    private(set) var boxes: [LocalMailbox] = []
    /// 지금 연 상자와 그 목록(요약). 본문·첨부는 고른 메일 한 통만 읽는다.
    private(set) var openedID: String?
    private(set) var mails: [ArchivedSummary] = []
    private(set) var isLoading = false
    private(set) var failure: String?
    /// 목록에서 고른 메일. 바뀌면 그 메일을 파일에서 읽는다.
    var selection: ArchivedSummary.ID? {
        didSet {
            guard selection != oldValue else { return }
            if let openedID { selections[openedID] = selection }
            loadSelected()
        }
    }
    /// 고른 메일 (본문·첨부까지)
    private(set) var selectedMail: ArchivedMail?

    @ObservationIgnored let directory: URL
    private var indexURL: URL { directory.appending(path: "index.json") }
    /// 상자마다 마지막으로 고른 메일
    @ObservationIgnored private var selections: [String: ArchivedSummary.ID] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// 상자를 연 뒤 고를 메일 (모든 폴더 검색 결과를 눌렀을 때)
    @ObservationIgnored var pendingSelection: ArchivedSummary.ID?

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appending(path: "index.json")) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            boxes = (try? decoder.decode([LocalMailbox].self, from: data)) ?? []
        }
    }

    func fileURL(_ box: LocalMailbox) -> URL { directory.appending(path: box.fileName) }
    /// 목록 색인: <id>.index-v<n>.json
    func summaryURL(_ id: String) -> URL { directory.appending(path: "\(id).index-v\(ArchiveIndex.version).json") }

    /// 검색: 메인 창 도구 막대의 검색 칸 글로 거른다. 제목·사람·본문·첨부 이름, 낱말이 모두 들어 있어야.
    func filtered(_ query: String) -> [ArchivedSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return mails }
        return mails.filter { MailArchive.matches($0.search, query: q) }
    }

    /// 모든 폴더 검색: 나의 Mac에 상자 전부의 색인에서 찾는다 (최근 메일부터, 많아야 200통).
    func searchAll(_ query: String) async -> [LocalHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !boxes.isEmpty else { return [] }
        let sources = boxes.map { ($0, summaryURL($0.id), fileURL($0)) }
        return await Task.detached(priority: .userInitiated) { () -> [LocalHit] in
            var hits: [LocalHit] = []
            for (box, indexFile, file) in sources {
                let list: [ArchivedSummary]
                if let data = try? Data(contentsOf: indexFile), let decoded = try? ArchiveIndex.decode(data) {
                    list = decoded
                } else if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
                    // 색인이 아직 없으면 만들어 둔다 (예전에 가져온 상자)
                    list = ArchiveIndex.summaries(ofMbox: data)
                    try? ArchiveIndex.encode(list).write(to: indexFile, options: .atomic)
                } else {
                    continue
                }
                hits += list.filter { MailArchive.matches($0.search, query: q) }
                    .map { LocalHit(boxID: box.id, boxName: box.name, summary: $0) }
            }
            return Array(hits.sorted { ($0.summary.date ?? .distantPast) > ($1.summary.date ?? .distantPast) }.prefix(200))
        }.value
    }

    // MARK: 가져오기

    /// 파일(.mbox, .eml, .emlx)이나 폴더의 메일을 앱 안에 mbox로 저장하고, 목록 색인을 만들어 둔다.
    func importMailbox(from url: URL) async throws -> LocalMailbox {
        let id = UUID().uuidString
        let target = directory.appending(path: "\(id).mbox")
        let indexFile = summaryURL(id)
        let dir = directory
        let count = try await Task.detached(priority: .userInitiated) { () throws -> Int in
            let raw = try ArchiveFile.rawMessages(url)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var out = Data()
            for message in raw {
                out.append(MailArchive.mboxEntry(message, date: MailArchive.parse(message).date))
            }
            try out.write(to: target, options: .atomic)
            let summaries = ArchiveIndex.summaries(ofMbox: out)
            try ArchiveIndex.encode(summaries).write(to: indexFile, options: .atomic)
            return summaries.count
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

    /// 상자를 연다: 색인만 읽으므로 바로 보인다. 색인이 없으면(예전에 가져온 상자) 한 번 만들어 저장한다.
    func open(_ id: String) async {
        if openedID == id && failure == nil && !mails.isEmpty {
            if let pending = pendingSelection { selection = pending; pendingSelection = nil }
            return
        }
        guard let box = boxes.first(where: { $0.id == id }) else { return }
        openedID = id
        failure = nil
        mails = []
        selectedMail = nil
        isLoading = true
        defer { isLoading = false }
        let file = fileURL(box)
        let indexFile = summaryURL(id)
        do {
            let list = try await Task.detached(priority: .userInitiated) { () throws -> [ArchivedSummary] in
                if let data = try? Data(contentsOf: indexFile), let list = try? ArchiveIndex.decode(data) { return list }
                let summaries = ArchiveIndex.summaries(ofMbox: try Data(contentsOf: file, options: .mappedIfSafe))
                try? ArchiveIndex.encode(summaries).write(to: indexFile, options: .atomic)
                return summaries
            }.value
            guard openedID == id else { return }
            mails = list
            let remembered = selections[id].flatMap { s in list.contains { $0.id == s } ? s : nil }
            let pending = pendingSelection.flatMap { p in list.contains { $0.id == p } ? p : nil }
            pendingSelection = nil
            selection = pending ?? remembered ?? list.first?.id
            loadSelected()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// 고른 메일 한 통만 파일에서 읽어 해석한다 (메인 스레드 밖에서).
    private func loadSelected() {
        loadTask?.cancel()
        guard let id = selection, let summary = mails.first(where: { $0.id == id }),
              let box = boxes.first(where: { $0.id == openedID }) else {
            selectedMail = nil
            return
        }
        if selectedMail?.id == id { return }
        let file = fileURL(box)
        loadTask = Task { [weak self] in
            let mail = await Task.detached(priority: .userInitiated) {
                try? ArchiveIndex.message(summary, inFile: file)
            }.value
            guard !Task.isCancelled, let self, self.selection == id else { return }
            self.selectedMail = mail
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
        try? FileManager.default.removeItem(at: summaryURL(id))
        boxes.removeAll { $0.id == id }
        selections[id] = nil
        if openedID == id {
            openedID = nil
            mails = []
            selectedMail = nil
            selection = nil
        }
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
