import ExchangeMailKit
import Foundation

// M23 계정 여러 개: 앱이 부르는 `service`는 이 안내자 하나다. 요청을 알맞은 계정의 서비스로 넘긴다.
// - 메일 하나에 대한 일(열기·읽음·옮기기·깃발…): 그 메일이 속한 계정. 목록을 받을 때 메일마다 주인 계정을 적어 둔다.
// - 폴더에 대한 일: 그 폴더의 계정 (폴더 목록을 받을 때 적어 둔다).
// - 회의 응답: 초대 메일의 계정.
// - 모든 계정에 걸친 일(깃발 표시·VIP·스마트 메일상자·모든 폴더 검색·모든 받은 편지함): 모든 계정에 묻고 합친다.
// - 계정 단위의 일(보내기·초안·규칙·자동 응답·범주): 지금 고른 계정 (`activeID`), 보내기는 `service(forAccount:)`로 직접.
// Exchange의 메일·폴더 id는 계정마다 달라 겹치지 않는다. 계정이 하나면 그 계정으로 그대로 넘긴다.

final class AccountRouter: MailService {
    let store: AccountStore
    private var folderOwner: [String: String] = [:]
    private var messageOwner: [String: String] = [:]
    private var eventOwner: [String: String] = [:]

    init(store: AccountStore) {
        self.store = store
    }

    // MARK: 누구의 서비스인가

    var active: MailAccount? { store.active }

    private func activeService() throws -> any MailService {
        guard let a = store.active else { throw AuthError.signedOut }
        return a.service
    }

    func service(forAccount id: String?) -> (any MailService)? {
        (id.flatMap { id in store.accounts.first { $0.id == id } } ?? store.active)?.service
    }

    /// 이 메일의 계정 id (모르면 지금 계정)
    func accountID(forMessage id: String) -> String? { messageOwner[id] ?? IMAP.parseID(id)?.account ?? store.active?.id }
    func accountID(forFolder id: String) -> String? { folderOwner[id] ?? IMAP.parseID(id)?.account ?? store.active?.id }

    private func forMessage(_ id: String) throws -> any MailService {
        if let owner = messageOwner[id], let s = service(forAccount: owner) { return s }
        // IMAP id에는 계정이 들어 있다 (M24)
        if let owner = IMAP.parseID(id)?.account, let s = service(forAccount: owner) { return s }
        return try activeService()
    }

    private func forFolder(_ id: String) throws -> any MailService {
        if let owner = folderOwner[id], let s = service(forAccount: owner) { return s }
        if let owner = IMAP.parseID(id)?.account, let s = service(forAccount: owner) { return s }
        return try activeService()
    }

    /// 계정 서비스에서 직접 받은 메일의 주인을 적어 둔다 (새 메일 확인처럼 안내자를 거치지 않은 목록)
    func noteOwner(_ messages: [MailMessage], account: String) { note(messages, account: account) }

    private func note(_ messages: [MailMessage], account: String?) {
        guard let account else { return }
        for m in messages { messageOwner[m.id] = account }
    }

    private func owner(of service: any MailService) -> String? {
        store.accounts.first { $0.service === service }?.id
    }

    // MARK: 폴더

    /// 지금 계정의 폴더 (예전 호출)
    func folders() async throws -> [MailFolder] {
        guard let a = store.active else { throw AuthError.signedOut }
        return try await folders(of: a)
    }

    /// 한 계정의 폴더. 폴더마다 주인 계정을 적어 둔다.
    func folders(of account: MailAccount) async throws -> [MailFolder] {
        let list = try await account.service.folders()
        for f in list { folderOwner[f.id] = account.id }
        return list
    }

    func createFolder(name: String, parentID: String?) async throws -> MailFolder {
        let s = try parentID.map(forFolder) ?? activeService()
        let f = try await s.createFolder(name: name, parentID: parentID)
        folderOwner[f.id] = owner(of: s)
        return f
    }

    func renameFolder(id: String, name: String) async throws { try await forFolder(id).renameFolder(id: id, name: name) }
    func deleteFolder(id: String) async throws { try await forFolder(id).deleteFolder(id: id) }

    // MARK: 목록

    func messages(folderID: String, search: String?, filter: MailFilter?, oldestFirst: Bool) async throws -> MessagePage {
        let s = try forFolder(folderID)
        let page = try await s.messages(folderID: folderID, search: search, filter: filter, oldestFirst: oldestFirst)
        note(page.messages, account: folderOwner[folderID] ?? store.active?.id)
        if let link = page.nextLink { nextOwner[link] = folderOwner[folderID] ?? store.active?.id }
        return page
    }

    /// 다음 쪽 링크 → 계정
    private var nextOwner: [String: String] = [:]

    func nextPage(_ link: String) async throws -> MessagePage {
        let account = nextOwner[link] ?? store.active?.id
        guard let s = service(forAccount: account) else { throw AuthError.signedOut }
        let page = try await s.nextPage(link)
        note(page.messages, account: account)
        if let next = page.nextLink { nextOwner[next] = account }
        return page
    }

    func categories() async throws -> [String] { (try? await exchangeService().categories()) ?? [] }

    /// 모든 계정에 묻는 질문. 계정 서비스를 클로저에 넘기면 Swift 6가 경합 위험으로 막으므로 질문을 값으로 넘긴다.
    private enum Query {
        case flagged
        case search(String)
        case sender(String)
        case collect(filter: String?)
    }

    private func ask(_ query: Query, _ s: any MailService) async throws -> MessagePage {
        switch query {
        case .flagged: try await s.flaggedMessages()
        case .search(let text): try await s.searchAll(text)
        case .sender(let address): try await s.messages(fromSender: address)
        case .collect(let filter): try await s.collectMessages(folderID: nil, filter: filter)
        }
    }

    /// 모든 계정에 같은 것을 묻고 최근 순으로 합친다. 계정이 하나면 그 결과를 그대로 (다음 쪽 포함).
    private func everyAccount(_ query: Query) async throws -> MessagePage {
        if store.accounts.count <= 1 {
            let page = try await ask(query, try activeService())
            note(page.messages, account: store.active?.id)
            if let link = page.nextLink { nextOwner[link] = store.active?.id }
            return page
        }
        var all: [MailMessage] = []
        var lastError: Error?
        for account in store.accounts {
            do {
                let page = try await ask(query, account.service)
                note(page.messages, account: account.id)
                all += page.messages
            } catch {
                lastError = error   // 한 계정이 실패해도 나머지는 보인다
            }
        }
        if all.isEmpty, let lastError { throw lastError }
        all.sort { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        return MessagePage(messages: all, nextLink: nil, serverFiltered: false)
    }

    func flaggedMessages() async throws -> MessagePage { try await everyAccount(.flagged) }
    func searchAll(_ text: String) async throws -> MessagePage { try await everyAccount(.search(text)) }
    func messages(fromSender address: String) async throws -> MessagePage { try await everyAccount(.sender(address)) }

    func collectMessages(folderID: String?, filter: String?) async throws -> MessagePage {
        if let folderID {
            let page = try await forFolder(folderID).collectMessages(folderID: folderID, filter: filter)
            note(page.messages, account: folderOwner[folderID])
            return page
        }
        return try await everyAccount(.collect(filter: filter))
    }

    /// 모든 받은 편지함: 계정마다 받은 편지함 첫 쪽을 합친다.
    func allInboxes(inboxIDs: [(account: String, folder: String)]) async throws -> MessagePage {
        var all: [MailMessage] = []
        var lastError: Error?
        for (account, folder) in inboxIDs {
            guard let s = service(forAccount: account) else { continue }
            folderOwner[folder] = account
            do {
                let page = try await s.messages(folderID: folder, search: nil, filter: nil, oldestFirst: false)
                note(page.messages, account: account)
                all += page.messages
            } catch {
                lastError = error
            }
        }
        if all.isEmpty, let lastError { throw lastError }
        all.sort { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        return MessagePage(messages: all, nextLink: nil, serverFiltered: false)
    }

    // MARK: 메일 하나

    func message(id: String) async throws -> MailMessage {
        let m = try await forMessage(id).message(id: id)
        if let e = m.event?.id { eventOwner[e] = messageOwner[id] ?? store.active?.id }
        return m
    }

    func attachments(messageID: String) async throws -> [FileAttachment] { try await forMessage(messageID).attachments(messageID: messageID) }
    func attachmentContent(messageID: String, attachmentID: String) async throws -> Data {
        try await forMessage(messageID).attachmentContent(messageID: messageID, attachmentID: attachmentID)
    }
    func setRead(id: String, read: Bool) async throws { try await forMessage(id).setRead(id: id, read: read) }

    /// 계정마다 모아 그 계정의 서비스에 한 번에 넘긴다 (1.0.2: Exchange는 묶음 요청, IMAP은 폴더별 한 명령).
    func setRead(ids: [String], read: Bool) async throws -> [String] {
        var groups: [(service: any MailService, ids: [String])] = []
        for id in ids {
            let s = try forMessage(id)
            if let i = groups.firstIndex(where: { $0.service === s }) { groups[i].ids.append(id) } else { groups.append((s, [id])) }
        }
        var done: [String] = []
        var lastError: Error?
        for group in groups {
            do {
                done += try await group.service.setRead(ids: group.ids, read: read)
            } catch {
                lastError = error
            }
        }
        if done.isEmpty, let lastError { throw lastError }
        return done
    }

    func move(id: String, to destination: String) async throws -> String {
        let account = messageOwner[id] ?? store.active?.id
        // Exchange는 다른 계정(사서함)의 폴더로 옮길 수 없다.
        if let target = folderOwner[destination], let account, target != account { throw AccountError.otherAccount }
        let newID = try await forMessage(id).move(id: id, to: destination)
        messageOwner[newID] = account
        return newID
    }

    func deleteMessage(id: String) async throws { try await forMessage(id).deleteMessage(id: id) }

    func conversation(id: String) async throws -> [MailMessage] {
        // iCloud·Gmail의 대화 id에는 계정이 들어 있다 (Exchange에 묻지 않는다)
        if let owner = IMAP.parseConversationID(id)?.account {
            guard let s = service(forAccount: owner) else { return [] }
            let list = try await s.conversation(id: id)
            note(list, account: owner)
            return list
        }
        // 대화 id만으로는 계정을 모른다: 지금 계정에 묻고, 없으면 다른 계정에도 묻는다.
        var tried = Set<String>()
        for account in [store.active].compactMap({ $0 }) + store.accounts where tried.insert(account.id).inserted {
            if let list = try? await account.service.conversation(id: id), !list.isEmpty {
                note(list, account: account.id)
                return list
            }
        }
        return []
    }

    func setFlag(id: String, flagged: Bool) async throws { try await forMessage(id).setFlag(id: id, flagged: flagged) }
    func copy(id: String, to destination: String) async throws {
        if let target = folderOwner[destination], let account = messageOwner[id], target != account {
            throw AccountError.otherAccount
        }
        try await forMessage(id).copy(id: id, to: destination)
    }
    func setImportance(id: String, importance: String) async throws {
        try await forMessage(id).setImportance(id: id, importance: importance)
    }
    func mimeContent(id: String) async throws -> Data { try await forMessage(id).mimeContent(id: id) }

    // MARK: 보내기·초안 (지금 계정; 작성 창은 service(forAccount:)로 직접 보낸다)

    func sendMIME(_ mime: Data) async throws { try await activeService().sendMIME(mime) }

    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String {
        let s = try oldID.map(forMessage) ?? activeService()
        let id = try await s.saveDraft(mime, preview: preview, replacing: oldID)
        messageOwner[id] = owner(of: s)
        return id
    }

    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws {
        try await forMessage(id).uploadAttachment(attachment, toMessage: id, progress: progress)
    }

    func sendDraft(id: String) async throws { try await forMessage(id).sendDraft(id: id) }
    func scheduleDraft(id: String, at date: Date) async throws { try await forMessage(id).scheduleDraft(id: id, at: date) }

    // MARK: 회의 (초대 메일의 계정)

    private func forEvent(_ id: String) throws -> any MailService {
        if let owner = eventOwner[id], let s = service(forAccount: owner) { return s }
        return try activeService()
    }

    func respond(toEvent eventID: String, with response: MeetingResponse) async throws {
        try await forEvent(eventID).respond(toEvent: eventID, with: response)
    }
    func event(id: String) async throws -> MailEvent { try await forEvent(id).event(id: id) }
    func meetingCheck(eventID: String) async throws -> MeetingCheck { try await forEvent(eventID).meetingCheck(eventID: eventID) }

    // MARK: 사서함 설정 (Exchange 계정)

    /// 규칙·자동 응답은 Exchange에만 있다: 지금 계정이 Exchange면 그 계정, 아니면 첫 Exchange 계정
    /// (지금 계정이 iCloud·Gmail이면 설정의 규칙·자동 응답 탭이 비거나 오류가 나지 않게).
    private func exchangeService() throws -> any MailService {
        if let a = store.active, a.imap == nil { return a.service }
        if let a = store.accounts.first(where: { $0.imap == nil }) { return a.service }
        throw IMAPError.unsupported
    }

    func rules() async throws -> [MessageRule] { try await exchangeService().rules() }
    func createRule(_ rule: MessageRule) async throws -> MessageRule { try await exchangeService().createRule(rule) }
    func setRule(id: String, enabled: Bool) async throws { try await exchangeService().setRule(id: id, enabled: enabled) }
    func deleteRule(id: String) async throws { try await exchangeService().deleteRule(id: id) }
    func automaticReplies() async throws -> AutomaticReplies { try await exchangeService().automaticReplies() }
    func setAutomaticReplies(_ settings: AutomaticReplies) async throws {
        try await exchangeService().setAutomaticReplies(settings)
    }
}

enum AccountError: LocalizedError {
    case otherAccount

    var errorDescription: String? {
        switch self {
        case .otherAccount: L("다른 계정의 폴더로는 옮기거나 복사할 수 없습니다.")
        }
    }
}
