import ExchangeMailKit
import Foundation

/// 오프라인 캐시를 끼운 메일 서비스 (S-026). 읽기는 성공하면 저장하고, 네트워크가 없으면 저장된 것을 돌려준다.
/// 쓰기(보내기, 옮기기, 읽음 표시)는 오프라인이면 하지 않고 `OfflineError`를 던진다.
final class CachedMailService: MailService {
    let remote: any MailService
    private let base: URL
    private let account: () -> String?
    /// 설정 > 계정 > "최근 메일을 이 Mac에 저장"
    private let enabled: () -> Bool
    /// 오프라인 상태가 바뀔 때 (AppModel이 막대를 띄운다)
    var onOfflineChange: ((Bool) -> Void)?
    private(set) var isOffline = false

    init(remote: any MailService, base: URL, account: @escaping () -> String?, enabled: @escaping () -> Bool) {
        self.remote = remote
        self.base = base
        self.account = account
        self.enabled = enabled
    }

    /// 지금 계정의 캐시. 로그인 전이면 nil.
    var cache: MailCache? {
        guard let email = account(), !email.isEmpty else { return nil }
        return MailCache.forAccount(email, base: base)
    }

    private var writableCache: MailCache? { enabled() ? cache : nil }

    private func setOffline(_ offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        onOfflineChange?(offline)
    }

    /// 서버에서 읽고 저장한다. 오프라인이면 `fallback`(저장된 것)을, 그것도 없으면 오류를 던진다.
    private func read<T>(_ load: () async throws -> T, save: (MailCache, T) -> Void,
                         fallback: (MailCache) -> T?) async throws -> T {
        do {
            let value = try await load()
            setOffline(false)
            if let c = writableCache { save(c, value) }
            return value
        } catch let error where OfflineError.isOffline(error) {
            setOffline(true)
            if let c = cache, let saved = fallback(c) { return saved }
            throw error
        }
    }

    /// 쓰기: 오프라인이면 하지 않는다.
    private func write<T>(_ what: String, _ action: () async throws -> T) async throws -> T {
        do {
            let value = try await action()
            setOffline(false)
            return value
        } catch let error where OfflineError.isOffline(error) {
            setOffline(true)
            throw OfflineError.unavailable(what)
        }
    }

    // MARK: 읽기

    func folders() async throws -> [MailFolder] {
        try await read({ try await remote.folders() }, save: { $0.saveFolders($1) }, fallback: { $0.folders() })
    }

    func messages(folderID: String, search: String?) async throws -> MessagePage {
        // 검색은 서버에서만 된다.
        if let search, !search.isEmpty {
            return try await write("검색할") { try await remote.messages(folderID: folderID, search: search) }
        }
        return try await read({ try await remote.messages(folderID: folderID, search: nil) },
                              save: { $0.saveList(folderID: folderID, messages: $1.messages, nextLink: $1.nextLink) },
                              fallback: { c in c.list(folderID: folderID).map { MessagePage(messages: $0.messages, nextLink: nil) } })
    }

    func nextPage(_ link: String) async throws -> MessagePage {
        try await write("더 불러올") { try await remote.nextPage(link) }
    }

    func message(id: String) async throws -> MailMessage {
        try await read({ try await remote.message(id: id) }, save: { $0.saveMessage($1) },
                       fallback: { $0.message(id: id)?.message })
    }

    func attachments(messageID: String) async throws -> [FileAttachment] {
        try await read({ try await remote.attachments(messageID: messageID) },
                       save: { $0.saveAttachments($1, messageID: messageID) },
                       fallback: { $0.message(id: messageID)?.attachments })
    }

    func conversation(id: String) async throws -> [MailMessage] {
        try await write("대화를 불러올") { try await remote.conversation(id: id) }
    }

    // MARK: 쓰기

    func setRead(id: String, read: Bool) async throws {
        try await write("읽음 상태를 바꿀") { try await remote.setRead(id: id, read: read) }
    }

    func move(id: String, to destination: String) async throws -> String {
        try await write("옮길") { try await remote.move(id: id, to: destination) }
    }

    func sendMIME(_ mime: Data) async throws {
        try await write("보낼") { try await remote.sendMIME(mime) }
    }

    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String {
        try await write("초안을 저장할") { try await remote.saveDraft(mime, preview: preview, replacing: oldID) }
    }

    func deleteMessage(id: String) async throws {
        try await write("지울") { try await remote.deleteMessage(id: id) }
    }

    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws {
        try await write("첨부를 올릴") { try await remote.uploadAttachment(attachment, toMessage: id, progress: progress) }
    }

    func sendDraft(id: String) async throws {
        try await write("보낼") { try await remote.sendDraft(id: id) }
    }

    /// 다시 연결: 폴더를 한 번 읽어 본다.
    func retry() async -> Bool {
        _ = try? await folders()
        return !isOffline
    }

    func clearCache() {
        cache?.clear()
    }
}
