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
    /// 캐시 파일 쓰기용 (메인 스레드 밖, 순서대로)
    private static let writer = DispatchQueue(label: "FAKUKUMail.cache-writer", qos: .utility)

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
    private func read<T: Sendable>(_ load: () async throws -> T, save: @escaping @Sendable (MailCache, T) -> Void,
                                   fallback: (MailCache) -> T?) async throws -> T {
        do {
            let value = try await load()
            setOffline(false)
            // 저장(JSON 만들기, 파일 쓰기, 오래된 것 정리)은 메인 스레드 밖에서 한다: 화면이 멈추지 않게.
            // 한 줄로 차례대로 쓴다 (본문을 쓴 뒤에 그 메일의 첨부를 쓰도록).
            if let c = writableCache { Self.writer.async { save(c, value) } }
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
            return try await write(L("검색할")) {
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
        try await write(L("범주를 불러올")) { try await remote.categories() }
    }

    func nextPage(_ link: String) async throws -> MessagePage {
        try await write(L("더 불러올")) { try await remote.nextPage(link) }
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

    func attachmentContent(messageID: String, attachmentID: String) async throws -> Data {
        try await write(L("첨부를 받을")) { try await remote.attachmentContent(messageID: messageID, attachmentID: attachmentID) }
    }

    func conversation(id: String) async throws -> [MailMessage] {
        try await write(L("대화를 불러올")) { try await remote.conversation(id: id) }
    }

    func searchAll(_ text: String) async throws -> MessagePage {
        try await write(L("검색할")) { try await remote.searchAll(text) }
    }

    func collectMessages(folderID: String?, filter: String?) async throws -> MessagePage {
        try await write(L("스마트 메일상자를 불러올")) { try await remote.collectMessages(folderID: folderID, filter: filter) }
    }

    func messages(fromSender address: String) async throws -> MessagePage {
        try await write(L("VIP 메일을 불러올")) { try await remote.messages(fromSender: address) }
    }

    func flaggedMessages() async throws -> MessagePage {
        try await read({ try await remote.flaggedMessages() },
                       save: { $0.saveList(folderID: FolderOrder.flaggedID, messages: $1.messages, nextLink: nil) },
                       fallback: { c in c.list(folderID: FolderOrder.flaggedID).map { MessagePage(messages: $0.messages, nextLink: nil) } })
    }

    // MARK: 쓰기

    func setFlag(id: String, flagged: Bool) async throws {
        try await write(L("깃발을 바꿀")) { try await remote.setFlag(id: id, flagged: flagged) }
    }

    func copy(id: String, to destination: String) async throws {
        try await write(L("복사할")) { try await remote.copy(id: id, to: destination) }
    }

    func setImportance(id: String, importance: String) async throws {
        try await write(L("우선 순위를 바꿀")) { try await remote.setImportance(id: id, importance: importance) }
    }

    func mimeContent(id: String) async throws -> Data {
        try await write(L("원본을 불러올")) { try await remote.mimeContent(id: id) }
    }

    func scheduleDraft(id: String, at date: Date) async throws {
        try await write(L("예약할")) { try await remote.scheduleDraft(id: id, at: date) }
    }

    func rules() async throws -> [MessageRule] {
        try await write(L("규칙을 불러올")) { try await remote.rules() }
    }

    func createRule(_ rule: MessageRule) async throws -> MessageRule {
        try await write(L("규칙을 만들")) { try await remote.createRule(rule) }
    }

    func setRule(id: String, enabled: Bool) async throws {
        try await write(L("규칙을 바꿀")) { try await remote.setRule(id: id, enabled: enabled) }
    }

    func deleteRule(id: String) async throws {
        try await write(L("규칙을 지울")) { try await remote.deleteRule(id: id) }
    }

    func automaticReplies() async throws -> AutomaticReplies {
        try await write(L("자동 응답을 불러올")) { try await remote.automaticReplies() }
    }

    func setAutomaticReplies(_ settings: AutomaticReplies) async throws {
        try await write(L("자동 응답을 저장할")) { try await remote.setAutomaticReplies(settings) }
    }

    func event(id: String) async throws -> MailEvent {
        try await write(L("일정을 확인할")) { try await remote.event(id: id) }
    }

    func meetingCheck(eventID: String) async throws -> MeetingCheck {
        try await write(L("일정을 확인할")) { try await remote.meetingCheck(eventID: eventID) }
    }

    func respond(toEvent eventID: String, with response: MeetingResponse) async throws {
        try await write(L("회의 초대에 답할")) { try await remote.respond(toEvent: eventID, with: response) }
    }

    func createFolder(name: String, parentID: String?) async throws -> MailFolder {
        try await write(L("폴더를 만들")) { try await remote.createFolder(name: name, parentID: parentID) }
    }

    func renameFolder(id: String, name: String) async throws {
        try await write(L("폴더 이름을 바꿀")) { try await remote.renameFolder(id: id, name: name) }
    }

    func deleteFolder(id: String) async throws {
        try await write(L("폴더를 지울")) { try await remote.deleteFolder(id: id) }
    }

    func setRead(id: String, read: Bool) async throws {
        try await write(L("읽음 상태를 바꿀")) { try await remote.setRead(id: id, read: read) }
    }

    func move(id: String, to destination: String) async throws -> String {
        try await write(L("옮길")) { try await remote.move(id: id, to: destination) }
    }

    func sendMIME(_ mime: Data) async throws {
        try await write(L("보낼")) { try await remote.sendMIME(mime) }
    }

    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String {
        try await write(L("초안을 저장할")) { try await remote.saveDraft(mime, preview: preview, replacing: oldID) }
    }

    func deleteMessage(id: String) async throws {
        try await write(L("지울")) { try await remote.deleteMessage(id: id) }
    }

    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws {
        try await write(L("첨부를 올릴")) { try await remote.uploadAttachment(attachment, toMessage: id, progress: progress) }
    }

    func sendDraft(id: String) async throws {
        try await write(L("보낼")) { try await remote.sendDraft(id: id) }
    }

    /// 다시 연결: 폴더를 한 번 읽어 본다.
    func retry() async -> Bool {
        _ = try? await folders()
        return !isOffline
    }

    /// 저장된 메일을 지운다. 쓰기 줄(writer)에 남은 저장이 다 끝난 뒤에 지운다:
    /// 바로 지우면 줄에 있던 저장이 그 뒤에 다시 써서 사본이 남았다 (계정 빼기, 설정의 저장된 메일 지우기).
    func clearCache() {
        guard let c = cache else { return }
        Self.writer.sync { c.clear() }
    }
}
