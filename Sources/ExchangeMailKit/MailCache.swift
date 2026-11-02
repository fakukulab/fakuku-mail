import CryptoKit
import Foundation

/// 오프라인 캐시 (S-026). 계정 하나의 폴더, 목록 첫 쪽, 메일 본문, 첨부를 파일로 둔다.
///   <root>/folders.json
///   <root>/lists/<폴더 id 해시>.json
///   <root>/messages/<메일 id 해시>.json
/// 파일 이름은 id의 SHA-256이라 id에 / 같은 글자가 있어도 안전하다.
public struct MailCache: Sendable {
    public let root: URL
    /// 본문은 최근 이 수만큼만 남긴다.
    public var maxMessages = 500
    /// 이보다 큰 일반 첨부는 이름과 크기만 남긴다 (인라인 그림은 본문에 필요해 항상 남긴다).
    public var maxAttachmentBytes = 2 * 1024 * 1024

    public init(root: URL) {
        self.root = root
    }

    /// 계정마다 다른 폴더: `<base>/<이메일 해시>`
    public static func forAccount(_ email: String, base: URL) -> MailCache {
        MailCache(root: base.appending(path: hash(email.lowercased()), directoryHint: .isDirectory))
    }

    public struct List: Codable, Equatable, Sendable {
        public var messages: [MailMessage]
        public var nextLink: String?
        public var savedAt: Date
    }

    public struct Message: Codable, Equatable, Sendable {
        public var message: MailMessage
        public var attachments: [FileAttachment]?
        public var savedAt: Date
    }

    // MARK: 쓰기

    public func saveFolders(_ folders: [MailFolder]) {
        write(folders, to: root.appending(path: "folders.json"))
    }

    public func saveList(folderID: String, messages: [MailMessage], nextLink: String?, at date: Date = Date()) {
        write(List(messages: messages, nextLink: nextLink, savedAt: date), to: listURL(folderID))
    }

    /// 본문을 저장한다. 첨부를 따로 받은 적이 있으면 그대로 둔다.
    public func saveMessage(_ message: MailMessage, at date: Date = Date()) {
        let old = self.message(id: message.id)
        write(Message(message: message, attachments: old?.attachments, savedAt: date), to: messageURL(message.id))
        prune()
    }

    /// 첨부를 저장한다. 큰 일반 첨부는 내용을 빼고 이름과 크기만 남긴다.
    public func saveAttachments(_ attachments: [FileAttachment], messageID: String, at date: Date = Date()) {
        guard var entry = message(id: messageID) else { return }
        entry.attachments = attachments.map { a in
            var copy = a
            let tooBig = (a.size ?? (a.contentBytes?.count ?? 0) * 3 / 4) > maxAttachmentBytes
            if a.isListed && tooBig { copy.contentBytes = nil }
            return copy
        }
        entry.savedAt = date
        write(entry, to: messageURL(messageID))
    }

    // MARK: 읽기

    public func folders() -> [MailFolder]? { read([MailFolder].self, from: root.appending(path: "folders.json")) }
    public func list(folderID: String) -> List? { read(List.self, from: listURL(folderID)) }
    public func message(id: String) -> Message? { read(Message.self, from: messageURL(id)) }

    // MARK: 정리

    /// 오래된 본문부터 지워 `maxMessages`만 남긴다.
    public func prune() {
        let dir = root.appending(path: "messages", directoryHint: .isDirectory)
        // 대부분은 한도 안이다: 파일 수만 빠르게 세고, 넘을 때만 날짜를 읽는다.
        guard ((try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0) > maxMessages else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys),
              files.count > maxMessages else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maxMessages) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 이 계정의 캐시를 모두 지운다.
    public func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 캐시가 차지하는 바이트
    public func sizeBytes() -> Int {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in e {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: helpers

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func listURL(_ folderID: String) -> URL {
        root.appending(path: "lists/\(Self.hash(folderID)).json")
    }

    func messageURL(_ id: String) -> URL {
        root.appending(path: "messages/\(Self.hash(id)).json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? GraphJSON.decoder().decode(type, from: data)
    }
}

/// 오프라인으로 볼 오류 (S-026)
public enum OfflineError: Error, LocalizedError, Equatable {
    /// 네트워크가 없어 이 작업을 할 수 없다
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let what): "오프라인이라 \(what) 수 없습니다. 연결되면 다시 해 주세요."
        }
    }

    /// 연결 끊김, 시간 초과, 호스트를 찾을 수 없음 등
    public static func isOffline(_ error: Error) -> Bool {
        if error is OfflineError { return true }
        guard let e = error as? URLError else { return false }
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                                      .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
                                      .internationalRoamingOff, .secureConnectionFailed]
        return codes.contains(e.code)
    }
}
