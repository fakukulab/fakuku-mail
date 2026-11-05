import ExchangeMailKit
import Foundation

// M24 iCloud·Gmail·IMAP 계정의 메일 서비스. 메일은 서버에 둔다 (Graph와 같다).
// 1단계: 폴더, 목록(50통씩), 본문과 첨부, 읽음·깃발, 옮기기·복사·지우기, 검색, 깃발 단 메일.
// 2단계(SMTP 보내기, 초안, 새 메일 즉시 알림)까지는 그 기능이 "아직 할 수 없음"을 알린다.
// id: "imap:<계정>:<폴더 경로>#<UID>" (Kit `IMAP.messageID`)

final class IMAPMailService: MailService {
    let accountID: String
    let config: IMAPAccountConfig
    private let connection: IMAPConnection
    /// 폴더 경로 → 종류 (inbox, sentitems …). folders()가 채운다.
    private var kinds: [String: String] = [:]
    /// 지운 메일을 옮길 휴지통 경로
    private var trashPath: String? { kinds.first { $0.value == "deleteditems" }?.key }
    /// 방금 연 메일의 첨부 (attachments(messageID:)가 다시 받지 않게)
    private var attachmentMemo: [String: [FileAttachment]] = [:]
    private static let pageSize = 50
    /// 서버에서 사라진 메일 (Graph의 404와 같게 다뤄 목록을 조용히 고친다)
    private static var notFound: GraphError {
        GraphError(status: 404, code: "ErrorItemNotFound", message: "The message is no longer on the server.")  // l10n: data
    }

    init(accountID: String, config: IMAPAccountConfig, password: String) {
        self.accountID = accountID
        self.config = config
        connection = IMAPConnection(host: config.imapHost, port: config.imapPort,
                                    username: config.username, password: password)
    }

    /// 계정 추가 때: 연결해서 로그인되는지 본다
    static func verify(_ config: IMAPAccountConfig, password: String) async throws {
        let c = IMAPConnection(host: config.imapHost, port: config.imapPort, username: config.username, password: password)
        try await c.connectIfNeeded()
        await c.logout()
    }

    func close() async { await connection.logout() }

    // MARK: id

    private func parts(_ id: String) throws -> (path: String, uid: Int) {
        guard let p = IMAP.parseID(id), p.account == accountID, let uid = p.uid else { throw IMAPError.server("id") }
        return (p.path, uid)
    }

    private func folderPath(_ id: String) throws -> String {
        guard let p = IMAP.parseID(id), p.account == accountID else { throw IMAPError.server("folder") }
        return p.path
    }

    // MARK: 폴더

    func folders() async throws -> [MailFolder] {
        let reply = try await connection.run("LIST \"\" \"*\"")
        var out: [MailFolder] = []
        var newKinds: [String: String] = [:]
        for values in reply.untagged {
            guard let entry = IMAP.listEntry(values), !entry.flags.contains("\\noselect"),
                  !entry.flags.contains("\\nonexistent") else { continue }
            let path = IMAP.decodeFolderName(entry.path)
            let kind = IMAP.kind(of: entry)
            if let kind { newKinds[path] = kind }
            let components = entry.delimiter.map { path.components(separatedBy: $0) } ?? [path]
            var folder = MailFolder(id: IMAP.folderID(account: accountID, path: path),
                                    displayName: kind == "inbox" ? L("받은 편지함") : (components.last ?? path),
                                    wellKnownName: kind == "allmail" ? nil : kind)
            if components.count > 1, let d = entry.delimiter {
                folder.parentFolderId = IMAP.folderID(account: accountID, path: components.dropLast().joined(separator: d))
            }
            out.append(folder)
        }
        kinds = newKinds
        // 읽지 않은 수와 전체 수 (폴더마다 STATUS 한 번)
        for i in out.indices {
            guard let p = IMAP.parseID(out[i].id)?.path,
                  let status = try? await connection.run([.text("STATUS "), .text(IMAP.quote(IMAP.encodeFolderName(p))),
                                                          .text(" (MESSAGES UNSEEN)")]),
                  let line = status.untagged.first(where: { $0.first?.text?.uppercased() == "STATUS" }),
                  let items = line.last?.items else { continue }
            var k = 0
            while k + 1 < items.count {
                switch items[k].text?.uppercased() {
                case "MESSAGES": out[i].totalItemCount = items[k + 1].int
                case "UNSEEN": out[i].unreadItemCount = items[k + 1].int
                default: break
                }
                k += 2
            }
        }
        return out
    }

    func createFolder(name: String, parentID: String?) async throws -> MailFolder {
        let parent = try parentID.map(folderPath)
        let path = parent.map { "\($0)/\(name)" } ?? name
        _ = try await connection.run("CREATE " + IMAP.quote(IMAP.encodeFolderName(path)))
        var f = MailFolder(id: IMAP.folderID(account: accountID, path: path), displayName: name)
        f.parentFolderId = parentID
        return f
    }

    func renameFolder(id: String, name: String) async throws {
        let old = try folderPath(id)
        let parent = old.contains("/") ? String(old[..<old.lastIndex(of: "/")!]) + "/" : ""
        _ = try await connection.run("RENAME " + IMAP.quote(IMAP.encodeFolderName(old)) + " "
                                     + IMAP.quote(IMAP.encodeFolderName(parent + name)))
    }

    func deleteFolder(id: String) async throws {
        let path = try folderPath(id)
        _ = try await connection.run("DELETE " + IMAP.quote(IMAP.encodeFolderName(path)))
    }

    // MARK: 목록

    /// 다음 쪽 링크: "imap-page:<폴더 id>|<이 순번 이하>"
    private func pageLink(folderID: String, below seq: Int) -> String? {
        seq >= 1 ? "imap-page:\(folderID)|\(seq)" : nil
    }

    func messages(folderID: String, search: String?, filter: MailFilter?, oldestFirst: Bool) async throws -> MessagePage {
        let path = try folderPath(folderID)
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
            let uids = try await searchUIDs(path: path, criteria: textCriteria(search))
            return MessagePage(messages: try await fetch(path: path, uids: Array(uids.suffix(Self.pageSize))),
                               nextLink: nil, serverFiltered: false)
        }
        let count = try await connection.exists(in: path)
        return try await page(folderID: folderID, path: path, top: count)
    }

    func nextPage(_ link: String) async throws -> MessagePage {
        guard link.hasPrefix("imap-page:"), let bar = link.lastIndex(of: "|"), let top = Int(link[link.index(after: bar)...]) else {
            throw IMAPError.server("page")
        }
        let folderID = String(link[link.index(link.startIndex, offsetBy: 10)..<bar])
        return try await page(folderID: folderID, path: try folderPath(folderID), top: top)
    }

    /// 순번 top부터 아래로 50통 (최근 메일이 위)
    private func page(folderID: String, path: String, top: Int) async throws -> MessagePage {
        guard top > 0 else { return MessagePage(messages: [], nextLink: nil, serverFiltered: false) }
        let low = max(1, top - Self.pageSize + 1)
        let reply = try await connection.run(select: path, "FETCH \(low):\(top) (\(IMAP.summaryItems))")
        let list = summaries(reply, path: path)
        return MessagePage(messages: list, nextLink: pageLink(folderID: folderID, below: low - 1), serverFiltered: false)
    }

    private func summaries(_ reply: IMAPReply, path: String) -> [MailMessage] {
        reply.untagged.compactMap { IMAP.fetchItems($0) }
            .compactMap { IMAP.summary($0, account: accountID, path: path) }
            .sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
    }

    private func fetch(path: String, uids: [Int]) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        let uidList = uids.map(String.init).joined(separator: ",")
        return summaries(try await connection.run(select: path, "UID FETCH \(uidList) (\(IMAP.summaryItems))"), path: path)
    }

    // MARK: 검색

    private func textCriteria(_ text: String) -> [IMAPPart] {
        [.text("CHARSET UTF-8 TEXT "), .literalOrQuoted(text)]
    }

    private func searchUIDs(path: String, criteria: [IMAPPart]) async throws -> [Int] {
        let reply = try await connection.run(select: path, [.text("UID SEARCH ")] + criteria)
        return reply.untagged.filter { $0.first?.text?.uppercased() == "SEARCH" }
            .flatMap { $0.dropFirst().compactMap(\.int) }.sorted()
    }

    /// 여러 폴더에서 찾는다 (휴지통·정크 제외). 최근 순 50통.
    private func searchFolders(_ criteria: [IMAPPart]) async throws -> MessagePage {
        if kinds.isEmpty { _ = try await folders() }
        let reply = try await connection.run("LIST \"\" \"*\"")
        let paths = reply.untagged.compactMap(IMAP.listEntry)
            .filter { !$0.flags.contains("\\noselect") && !["deleteditems", "junkemail", "allmail"].contains(IMAP.kind(of: $0) ?? "") }
            .map { IMAP.decodeFolderName($0.path) }
        var all: [MailMessage] = []
        for path in paths {
            guard let uids = try? await searchUIDs(path: path, criteria: criteria), !uids.isEmpty else { continue }
            all += (try? await fetch(path: path, uids: Array(uids.suffix(Self.pageSize)))) ?? []
        }
        all.sort { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        return MessagePage(messages: Array(all.prefix(Self.pageSize)), nextLink: nil, serverFiltered: false)
    }

    func searchAll(_ text: String) async throws -> MessagePage { try await searchFolders(textCriteria(text)) }
    func flaggedMessages() async throws -> MessagePage { try await searchFolders([.text("FLAGGED")]) }
    func messages(fromSender address: String) async throws -> MessagePage {
        try await searchFolders([.text("FROM "), .literalOrQuoted(address)])
    }

    /// 스마트 메일상자: Graph `$filter`는 IMAP에 없으므로 폴더의 최근 메일을 주고 앱이 거른다.
    func collectMessages(folderID: String?, filter: String?) async throws -> MessagePage {
        guard let folderID else { return MessagePage(messages: [], nextLink: nil, serverFiltered: false) }
        var page = try await messages(folderID: folderID, search: nil, filter: nil, oldestFirst: false)
        page.nextLink = nil
        return page
    }

    func categories() async throws -> [String] { [] }

    // MARK: 메일 하나

    func message(id: String) async throws -> MailMessage {
        let (path, uid) = try parts(id)
        let reply = try await connection.run(select: path, "UID FETCH \(uid) (\(IMAP.summaryItems) BODY.PEEK[])")
        guard let items = reply.untagged.compactMap(IMAP.fetchItems).first(where: { $0["UID"]?.int == uid }),
              let base = IMAP.summary(items, account: accountID, path: path) else { throw Self.notFound }
        let (message, files) = IMAP.detail(base, mime: IMAP.bodySection(items) ?? Data())
        attachmentMemo = [id: files]   // 열린 메일 하나만 기억한다
        return message
    }

    func attachments(messageID: String) async throws -> [FileAttachment] {
        if let memo = attachmentMemo[messageID] { return memo }
        _ = try await message(id: messageID)
        return attachmentMemo[messageID] ?? []
    }

    func attachmentContent(messageID: String, attachmentID: String) async throws -> Data {
        let list = try await attachments(messageID: messageID)
        guard let data = list.first(where: { $0.id == attachmentID })?.data else { throw Self.notFound }
        return data
    }

    func mimeContent(id: String) async throws -> Data {
        let (path, uid) = try parts(id)
        let reply = try await connection.run(select: path, "UID FETCH \(uid) (UID BODY.PEEK[])")
        guard let items = reply.untagged.compactMap(IMAP.fetchItems).first(where: { $0["UID"]?.int == uid }),
              let data = IMAP.bodySection(items) else { throw Self.notFound }
        return data
    }

    /// 대화 묶기는 2단계 (IMAP에는 대화 id가 없다: References로 묶는다)
    func conversation(id: String) async throws -> [MailMessage] { [] }

    // MARK: 표시

    private func store(_ id: String, _ change: String) async throws {
        let (path, uid) = try parts(id)
        _ = try await connection.run(select: path, "UID STORE \(uid) \(change)")
    }

    func setRead(id: String, read: Bool) async throws {
        try await store(id, read ? "+FLAGS.SILENT (\\Seen)" : "-FLAGS.SILENT (\\Seen)")
    }

    func setFlag(id: String, flagged: Bool) async throws {
        try await store(id, flagged ? "+FLAGS.SILENT (\\Flagged)" : "-FLAGS.SILENT (\\Flagged)")
    }

    func setImportance(id: String, importance: String) async throws { throw IMAPError.unsupported }

    // MARK: 옮기기·복사·지우기

    func move(id: String, to destination: String) async throws -> String {
        let (path, uid) = try parts(id)
        let target = try folderPath(destination)
        let reply: IMAPReply
        do {
            reply = try await connection.run(select: path, "UID MOVE \(uid) " + IMAP.quote(IMAP.encodeFolderName(target)))
        } catch IMAPError.server {
            // MOVE가 없는 서버: 복사하고 지운다
            let copied = try await connection.run(select: path, "UID COPY \(uid) " + IMAP.quote(IMAP.encodeFolderName(target)))
            _ = try await connection.run(select: path, "UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            _ = try? await connection.run(select: path, "UID EXPUNGE \(uid)")
            return newID(copied, target: target) ?? IMAP.folderID(account: accountID, path: target)
        }
        return newID(reply, target: target) ?? IMAP.folderID(account: accountID, path: target)
    }

    /// "[COPYUID <uidvalidity> <옛 uid> <새 uid>]" (RFC 4315)에서 새 id. MOVE는 이것을 "* OK"로 먼저 보내기도 한다.
    private func newID(_ reply: IMAPReply, target: String) -> String? {
        let texts = [reply.text] + reply.untagged.map { $0.compactMap(\.text).joined(separator: " ") }
        for t in texts {
            guard let r = t.range(of: "[COPYUID ", options: .caseInsensitive) else { continue }
            let fields = t[r.upperBound...].split(separator: " ")
            if fields.count >= 3, let uid = Int(fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "]"))) {
                return IMAP.messageID(account: accountID, path: target, uid: uid)
            }
        }
        return nil
    }

    func copy(id: String, to destination: String) async throws {
        let (path, uid) = try parts(id)
        let target = try folderPath(destination)
        _ = try await connection.run(select: path, "UID COPY \(uid) " + IMAP.quote(IMAP.encodeFolderName(target)))
    }

    /// 휴지통이 아니면 휴지통으로, 휴지통 안이면 아주 지운다.
    func deleteMessage(id: String) async throws {
        let (path, uid) = try parts(id)
        if kinds.isEmpty { _ = try? await folders() }
        if let trash = trashPath, trash != path {
            _ = try await move(id: id, to: IMAP.folderID(account: accountID, path: trash))
            return
        }
        _ = try await connection.run(select: path, "UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        _ = try? await connection.run(select: path, "UID EXPUNGE \(uid)")
    }

    // MARK: 2단계 (보내기, 초안)

    func sendMIME(_ mime: Data) async throws { throw IMAPError.unsupported }
    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String { throw IMAPError.unsupported }
    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws { throw IMAPError.unsupported }
    func sendDraft(id: String) async throws { throw IMAPError.unsupported }
    func scheduleDraft(id: String, at date: Date) async throws { throw IMAPError.unsupported }

    // MARK: Exchange에만 있는 기능

    func respond(toEvent eventID: String, with response: MeetingResponse) async throws { throw IMAPError.unsupported }
    func event(id: String) async throws -> MailEvent { throw IMAPError.unsupported }
    func meetingCheck(eventID: String) async throws -> MeetingCheck { throw IMAPError.unsupported }
    func rules() async throws -> [MessageRule] { [] }
    func createRule(_ rule: MessageRule) async throws -> MessageRule { throw IMAPError.unsupported }
    func setRule(id: String, enabled: Bool) async throws { throw IMAPError.unsupported }
    func deleteRule(id: String) async throws { throw IMAPError.unsupported }
    func automaticReplies() async throws -> AutomaticReplies { throw IMAPError.unsupported }
    func setAutomaticReplies(_ settings: AutomaticReplies) async throws { throw IMAPError.unsupported }
}
