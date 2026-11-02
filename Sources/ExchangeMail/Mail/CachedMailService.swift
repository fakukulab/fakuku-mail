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

    func messages(folderID: String, search: String?, filter: MailFilter?, oldestFirst: Bool) async throws -> MessagePage {
        // 검색은 서버에서만 된다.
        if let search, !search.isEmpty {
            return try await write("검색할") {
                try await remote.messages(folderID: folderID, search: search, filter: filter, oldestFirst: oldestFirst)
            }
        }
        // 거르거나 뒤집은 목록은 폴더 목록으로 저장하지 않는다. 오프라인이면 저장된 목록을 앱이 거른다.
        let plain = !(filter?.isActive ?? false) && !oldestFirst
        return try await read({ try await remote.messages(folderID: folderID, search: nil, filter: filter, oldestFirst: oldestFirst) },
                              save: { if plain { $0.saveList(folderID: folderID, messages: $1.messages, nextLink: $1.nextLink) } },
                              fallback: { c in
                                  c.list(folderID: folderID).map { MessagePage(messages: $0.messages, nextLink: nil, serverFiltered: false) }
                              })
    }

    func categories() async throws -> [String] {
        try await write("범주를 불러올") { try await remote.categories() }
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

    func searchAll(_ text: String) async throws -> MessagePage {
        try await write("검색할") { try await remote.searchAll(text) }
    }

    func flaggedMessages() async throws -> MessagePage {
        try await read({ try await remote.flaggedMessages() },
                       save: { $0.saveList(folderID: FolderOrder.flaggedID, messages: $1.messages, nextLink: nil) },
                       fallback: { c in c.list(folderID: FolderOrder.flaggedID).map { MessagePage(messages: $0.messages, nextLink: nil) } })
    }

    // MARK: 쓰기

    func setFlag(id: String, flagged: Bool) async throws {
        try await write("깃발을 바꿀") { try await remote.setFlag(id: id, flagged: flagged) }
    }

    func scheduleDraft(id: String, at date: Date) async throws {
        try await write("예약할") { try await remote.scheduleDraft(id: id, at: date) }
    }

    func rules() async throws -> [MessageRule] {
        try await write("규칙을 불러올") { try await remote.rules() }
    }

    func createRule(_ rule: MessageRule) async throws -> MessageRule {
        try await write("규칙을 만들") { try await remote.createRule(rule) }
    }

    func setRule(id: String, enabled: Bool) async throws {
        try await write("규칙을 바꿀") { try await remote.setRule(id: id, enabled: enabled) }
    }

    func deleteRule(id: String) async throws {
        try await write("규칙을 지울") { try await remote.deleteRule(id: id) }
    }

    func automaticReplies() async throws -> AutomaticReplies {
        try await write("자동 응답을 불러올") { try await remote.automaticReplies() }
    }

    func setAutomaticReplies(_ settings: AutomaticReplies) async throws {
        try await write("자동 응답을 저장할") { try await remote.setAutomaticReplies(settings) }
    }

    func event(id: String) async throws -> MailEvent {
        try await write("일정을 확인할") { try await remote.event(id: id) }
    }

    func respond(toEvent eventID: String, with response: MeetingResponse) async throws {
        try await write("회의 초대에 답할") { try await remote.respond(toEvent: eventID, with: response) }
    }

    func createFolder(name: String, parentID: String?) async throws -> MailFolder {
        try await write("폴더를 만들") { try await remote.createFolder(name: name, parentID: parentID) }
    }

    func renameFolder(id: String, name: String) async throws {
        try await write("폴더 이름을 바꿀") { try await remote.renameFolder(id: id, name: name) }
    }

    func deleteFolder(id: String) async throws {
        try await write("폴더를 지울") { try await remote.deleteFolder(id: id) }
    }

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
