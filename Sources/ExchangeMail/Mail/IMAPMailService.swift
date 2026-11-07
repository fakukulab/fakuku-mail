import ExchangeMailKit
import Foundation

// M24 iCloud·Gmail·IMAP 계정의 메일 서비스. 메일은 서버에 둔다 (Graph와 같다).
// 1단계: 폴더, 목록(50통씩), 본문과 첨부, 읽음·깃발, 옮기기·복사·지우기, 검색, 깃발 단 메일.
// 2단계(SMTP 보내기, 초안, 새 메일 즉시 알림)까지는 그 기능이 "아직 할 수 없음"을 알린다.
// id: "imap:<계정>:<폴더 경로>#<UID>" (Kit `IMAP.messageID`)

final class IMAPMailService: MailService {
    let accountID: String
    let config: IMAPAccountConfig
    /// 연결 여러 개 (M24 속도): 미리 받기·폴더 세기가 도는 동안에도 클릭한 메일과 지우기는 놀고 있는 연결로 바로 간다.
    private let pool: [IMAPConnection]
    /// 연결마다 지금 맡은 명령 수 (가장 한가한 연결을 고른다)
    private var load: [Int]
    private static let poolSize = 3
    /// 보내기 (SMTP)
    private let smtp: SMTPClient
    private let password: String
    /// 목록에서 본 메일의 Message-ID (옮긴 뒤 새 UID를 찾는 데 쓴다. 서버에 다시 묻지 않게)
    private var headerMemo: [String: String] = [:]
    /// 옮긴 메일의 임시 UID (음수, 겹치지 않게)
    private var pendingCounter = 0
    /// 폴더 경로 → 종류 (inbox, sentitems …). folders()가 채운다.
    private var kinds: [String: String] = [:]
    /// 지운 메일을 옮길 휴지통 경로
    private var trashPath: String? { kinds.first { $0.value == "deleteditems" }?.key }
    /// 방금 연 메일의 첨부 (attachments(messageID:)가 다시 받지 않게)
    private var attachmentMemo: [String: [FileAttachment]] = [:]
    private static let pageSize = 50

    // MARK: Gmail (M25)

    private var isGmail: Bool { config.provider == .gmail }
    /// Gmail 전체 보관함 경로 ([Gmail]/All Mail, 한국어 Gmail이면 [Gmail]/전체보관함)
    private var allMailPath: String?
    /// 목록에 받는 항목: Gmail은 대화 번호(X-GM-THRID)도 받는다
    private var summaryItems: String { isGmail ? IMAP.summaryItems + " X-GM-THRID" : IMAP.summaryItems }  // l10n: data
    /// 서버에서 사라진 메일 (Graph의 404와 같게 다뤄 목록을 조용히 고친다)
    private static var notFound: GraphError {
        GraphError(status: 404, code: "ErrorItemNotFound", message: "The message is no longer on the server.")  // l10n: data
    }

    init(accountID: String, config: IMAPAccountConfig, password: String) {
        self.accountID = accountID
        self.config = config
        pool = (0..<Self.poolSize).map { _ in
            IMAPConnection(host: config.imapHost, port: config.imapPort, username: config.username, password: password)
        }
        load = Array(repeating: 0, count: Self.poolSize)
        smtp = SMTPClient(config: config, password: password)
        self.password = password
    }

    // MARK: 연결 고르기

    /// 연결마다 마지막으로 고른 폴더 (같은 폴더를 고른 한가한 연결이 있으면 그리로: SELECT를 아낀다)
    private var selectedOn: [String?] = Array(repeating: nil, count: poolSize)

    private func pick(for path: String?) -> Int {
        if let path, let i = load.indices.first(where: { load[$0] == 0 && selectedOn[$0] == path }) { return i }
        // 한가한 연결 가운데, 될 수 있으면 다른 폴더를 붙들고 있지 않은 것
        return load.indices.min { (load[$0], selectedOn[$0] == nil ? 0 : 1) < (load[$1], selectedOn[$1] == nil ? 0 : 1) } ?? 0
    }

    private func run(select path: String? = nil, _ parts: [IMAPPart]) async throws -> IMAPReply {
        let i = pick(for: path)
        load[i] += 1
        if let path { selectedOn[i] = path }
        defer { load[i] -= 1 }
        return try await pool[i].run(select: path, parts)
    }

    /// 연결을 미리 열어 둔다 (첫 클릭이 TLS·로그인을 기다리지 않게)
    func warmUp() {
        for c in pool { Task { try? await c.connectIfNeeded() } }
    }

    private func run(select path: String? = nil, _ command: String) async throws -> IMAPReply {
        try await run(select: path, [.text(command)])
    }

    /// 폴더의 첫 쪽 (늘 새로 연 폴더에서, 한 연결로)
    private func latest(in path: String, count: Int = 50) async throws -> (low: Int, reply: IMAPReply) {
        let i = pick(for: path)
        load[i] += 1
        selectedOn[i] = path
        defer { load[i] -= 1 }
        return try await pool[i].latest(in: path, count: count, items: summaryItems)
    }

    /// 계정 추가 때: 연결해서 로그인되는지 본다
    static func verify(_ config: IMAPAccountConfig, password: String) async throws {
        let c = IMAPConnection(host: config.imapHost, port: config.imapPort, username: config.username, password: password)
        try await c.connectIfNeeded()
        await c.logout()
    }

    func close() async {
        watchTask?.cancel()
        watchTask = nil
        await idleConnection.logout()
        for c in pool { await c.logout() }
    }

    // MARK: 새 메일 즉시 알림 (IDLE)

    /// 받은 편지함을 지켜보는 연결 (IDLE 전용)
    private lazy var idleConnection = IMAPConnection(host: config.imapHost, port: config.imapPort,
                                                      username: config.username, password: password)
    private var watchTask: Task<Void, Never>?

    /// 받은 편지함에 새 메일이 오거나(다른 기기에서 읽거나 지워도) 바뀌면 `onChange`를 부른다.
    /// 서버가 IDLE을 모르면 그만둔다 (앱의 2분 확인이 대신한다). 연결이 끊기면 조금 기다렸다 다시 붙는다.
    func startWatching(onChange: @escaping @MainActor () -> Void) {
        guard watchTask == nil else { return }
        let connection = idleConnection
        watchTask = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    // 서버는 30분 안에 IDLE을 끊는다: 25분마다 새로 건다
                    if try await connection.idle(in: "INBOX", wait: 25 * 60) {  // l10n: data
                        self?.recentMemo["INBOX"] = nil   // l10n: data
                        onChange()
                    }
                    failures = 0
                } catch IMAPError.unsupported {
                    return
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    // 오프라인·서버 오류: 30초, 1분, 2분 … 최대 5분 기다렸다 다시
                    let delay = min(300, 30 * (1 << min(failures - 1, 4)))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    // MARK: id

    private func parts(_ id: String) throws -> (path: String, uid: Int) {
        guard let p = IMAP.parseID(id), p.account == accountID, let uid = p.uid else { throw IMAPError.server("id") }
        return (p.path, uid)
    }

    /// 폴더 id → 서버 경로. 앱은 Graph처럼 잘 알려진 이름("deleteditems", "archive" …)으로도 부른다:
    /// 그때는 서버가 알려 준 그 종류의 폴더 (iCloud "Deleted Messages", Gmail "[Gmail]/Trash").
    private func folderPath(_ id: String) async throws -> String {
        if let p = IMAP.parseID(id) {
            guard p.account == accountID else { throw IMAPError.server(L("다른 계정의 폴더입니다.")) }
            return p.path
        }
        if id.lowercased() == "inbox" { return "INBOX" }  // l10n: data
        if kinds.isEmpty { _ = try await folders() }
        if let path = kinds.first(where: { $0.value == id.lowercased() })?.key { return path }
        throw IMAPError.missingFolder(id)
    }

    // MARK: 폴더

    func folders() async throws -> [MailFolder] {
        let reply = try await run("LIST \"\" \"*\"")
        var out: [MailFolder] = []
        var newKinds: [String: String] = [:]
        var newAllMail: String?
        for values in reply.untagged {
            guard let entry = IMAP.listEntry(values), !entry.flags.contains("\\noselect"),
                  !entry.flags.contains("\\nonexistent") else { continue }
            let path = IMAP.decodeFolderName(entry.path)
            var kind = IMAP.kind(of: entry)
            if isGmail {
                // Gmail의 별표·중요 라벨은 다른 메일함의 메일을 다시 보여 줄 뿐이라 사이드바에 넣지 않는다 (깃발 표시가 별표)
                if entry.flags.contains("\\flagged") || entry.flags.contains("\\important") { continue }
                // 전체 보관함: 보관하면 받은 편지함 라벨만 떼어 여기에 남는다 → 보관 폴더로 쓴다
                if kind == "allmail" {
                    newAllMail = path
                    if !reply.untagged.contains(where: { IMAP.listEntry($0)?.flags.contains("\\archive") == true }) { kind = "archive" }
                }
            }
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
        allMailPath = newAllMail
        warmRecent()
        // 읽지 않은 수와 전체 수: 폴더마다 STATUS 한 번, 연결 여러 개로 나눠 동시에
        let paths = out.map { IMAP.parseID($0.id)?.path }
        // (작업 그룹은 Swift 6.2 영역 검사기가 해석하지 못해 빌드가 멈춘다: 폴더마다 Task를 띄우고 차례로 기다린다)
        let tasks = paths.map { path in
            Task { () -> [IMAPValue]? in
                guard let path else { return nil }
                return await self.status(of: path)
            }
        }
        var counts: [(Int, [IMAPValue])] = []
        for (i, task) in tasks.enumerated() {
            if let items = await task.value { counts.append((i, items)) }
        }
        for (i, items) in counts {
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

    private func status(of path: String) async -> [IMAPValue]? {
        guard let status = try? await run([.text("STATUS " + IMAP.quote(IMAP.encodeFolderName(path)) + " (MESSAGES UNSEEN)")]),
              let line = status.untagged.first(where: { $0.first?.text?.uppercased() == "STATUS" }) else { return nil }
        return line.last?.items
    }

    func createFolder(name: String, parentID: String?) async throws -> MailFolder {
        var parent: String?
        if let parentID { parent = try await folderPath(parentID) }
        let path = parent.map { "\($0)/\(name)" } ?? name
        _ = try await run("CREATE " + IMAP.quote(IMAP.encodeFolderName(path)))
        var f = MailFolder(id: IMAP.folderID(account: accountID, path: path), displayName: name)
        f.parentFolderId = parentID
        return f
    }

    func renameFolder(id: String, name: String) async throws {
        let old = try await folderPath(id)
        let parent = old.contains("/") ? String(old[..<old.lastIndex(of: "/")!]) + "/" : ""
        _ = try await run("RENAME " + IMAP.quote(IMAP.encodeFolderName(old)) + " "
                                     + IMAP.quote(IMAP.encodeFolderName(parent + name)))
    }

    func deleteFolder(id: String) async throws {
        let path = try await folderPath(id)
        _ = try await run("DELETE " + IMAP.quote(IMAP.encodeFolderName(path)))
    }

    // MARK: 목록

    /// 다음 쪽 링크: "imap-page:<폴더 id>|<이 순번 이하>"
    private func pageLink(folderID: String, below seq: Int) -> String? {
        seq >= 1 ? "imap-page:\(folderID)|\(seq)" : nil
    }

    func messages(folderID: String, search: String?, filter: MailFilter?, oldestFirst: Bool) async throws -> MessagePage {
        let path = try await folderPath(folderID)
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
            let uids = try await searchUIDs(path: path, criteria: textCriteria(search))
            return MessagePage(messages: try await fetch(path: path, uids: Array(uids.suffix(Self.pageSize))),
                               nextLink: nil, serverFiltered: false)
        }
        let (low, reply) = try await latest(in: path)
        return MessagePage(messages: summaries(reply, path: path), nextLink: pageLink(folderID: folderID, below: low - 1),
                           serverFiltered: false)
    }

    func nextPage(_ link: String) async throws -> MessagePage {
        guard link.hasPrefix("imap-page:"), let bar = link.lastIndex(of: "|"), let top = Int(link[link.index(after: bar)...]) else {
            throw IMAPError.server("page")
        }
        let folderID = String(link[link.index(link.startIndex, offsetBy: 10)..<bar])
        return try await page(folderID: folderID, path: try await folderPath(folderID), top: top)
    }

    /// 순번 top부터 아래로 50통 (최근 메일이 위)
    private func page(folderID: String, path: String, top: Int) async throws -> MessagePage {
        guard top > 0 else { return MessagePage(messages: [], nextLink: nil, serverFiltered: false) }
        let low = max(1, top - Self.pageSize + 1)
        let reply = try await run(select: path, "FETCH \(low):\(top) (\(summaryItems))")
        let list = summaries(reply, path: path)
        return MessagePage(messages: list, nextLink: pageLink(folderID: folderID, below: low - 1), serverFiltered: false)
    }

    private func summaries(_ reply: IMAPReply, path: String) -> [MailMessage] {
        let list = reply.untagged.compactMap { IMAP.fetchItems($0) }
            .compactMap { IMAP.summary($0, account: accountID, path: path) }
            .sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        if headerMemo.count > 5000 { headerMemo = [:] }
        for m in list { if let h = m.internetMessageId, !h.isEmpty { headerMemo[m.id] = h } }
        return list
    }

    private func fetch(path: String, uids: [Int]) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        let uidList = uids.map(String.init).joined(separator: ",")
        return summaries(try await run(select: path, "UID FETCH \(uidList) (\(summaryItems))"), path: path)
    }

    // MARK: 검색

    private func textCriteria(_ text: String) -> [IMAPPart] {
        [.text("CHARSET UTF-8 TEXT "), .literalOrQuoted(text)]
    }

    private func searchUIDs(path: String, criteria: [IMAPPart]) async throws -> [Int] {
        let reply = try await run(select: path, [.text("UID SEARCH ")] + criteria)
        return reply.untagged.filter { $0.first?.text?.uppercased() == "SEARCH" }
            .flatMap { $0.dropFirst().compactMap(\.int) }.sorted()
    }

    /// 여러 폴더에서 찾는다 (휴지통·정크 제외). 최근 순 50통.
    private func searchFolders(_ criteria: [IMAPPart], limit: Int = 50) async throws -> MessagePage {
        if kinds.isEmpty { _ = try await folders() }
        let paths: [String]
        if isGmail, let allMailPath {
            // Gmail: 전체 보관함 하나만 찾으면 된다 (라벨마다 같은 메일이 또 나오지 않게)
            paths = [allMailPath]
        } else {
            let reply = try await run("LIST \"\" \"*\"")
            paths = reply.untagged.compactMap(IMAP.listEntry)
                .filter { !$0.flags.contains("\\noselect") && !["deleteditems", "junkemail", "allmail"].contains(IMAP.kind(of: $0) ?? "") }
                .map { IMAP.decodeFolderName($0.path) }
        }
        // 폴더마다 동시에 찾는다 (연결 여러 개가 나눠 맡는다)
        let tasks = paths.map { path in
            Task { () -> [MailMessage] in
                guard let uids = try? await self.searchUIDs(path: path, criteria: criteria), !uids.isEmpty else { return [] }
                return (try? await self.fetch(path: path, uids: Array(uids.suffix(limit)))) ?? []
            }
        }
        var all: [MailMessage] = []
        for task in tasks { all += await task.value }
        all = Self.uniqueByMessageID(all)
        all.sort { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        return MessagePage(messages: Array(all.prefix(limit)), nextLink: nil, serverFiltered: false)
    }

    /// 같은 메일(Message-ID가 같은 것)이 여러 폴더·라벨에 있으면 앞의 것만 남긴다
    static func uniqueByMessageID(_ list: [MailMessage]) -> [MailMessage] {
        var seen = Set<String>()
        return list.filter { m in
            guard let key = m.internetMessageId?.lowercased(), !key.isEmpty else { return true }
            return seen.insert(key).inserted
        }
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
        let reply = try await run(select: path, "UID FETCH \(uid) (\(summaryItems) BODY.PEEK[])")
        guard let items = reply.untagged.compactMap(IMAP.fetchItems).first(where: { $0["UID"]?.int == uid }),
              let base = IMAP.summary(items, account: accountID, path: path) else { throw Self.notFound }
        var (message, files) = IMAP.detail(base, mime: IMAP.bodySection(items) ?? Data())
        attachmentMemo = [id: files]   // 열린 메일 하나만 기억한다
        // 회의 초대(.ics): 회의 막대와 수락·미정·거절, 맥 캘린더 (1.0.3)
        if let invite = ICSInvite.find(in: files.map { ($0.name, $0.contentType ?? "", $0.data ?? Data()) }) {
            let eventID = ICSInvite.eventID(account: accountID, uid: invite.uid)
            inviteMemo[eventID] = invite
            Self.rememberInvite(eventID, messageID: id)
            message.event = invite.mailEvent(id: eventID, response: Self.savedResponse(eventID) ?? invite.myResponse(me: me))
            if invite.isRequest(me: me) { message.odataType = "#microsoft.graph.eventMessageRequest" }
            // 본문이 없는 초대·응답·취소 메일(Outlook·Exchange의 응답 등)은 무슨 메일인지 글로 보인다
            if (message.body?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let text = invite.summaryText()
                message.body = .init(contentType: "text", content: text)
                message.bodyPreview = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            }
        }
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
        let reply = try await run(select: path, "UID FETCH \(uid) (UID BODY.PEEK[])")
        guard let items = reply.untagged.compactMap(IMAP.fetchItems).first(where: { $0["UID"]?.int == uid }),
              let data = IMAP.bodySection(items) else { throw Self.notFound }
        return data
    }

    /// 대화의 모든 메일. 같은 대화 = 목록에서 정한 대화 id가 같은 메일 (`IMAP.threadRoot`).
    /// 받은 편지함·보낸 편지함·보관과 메일이 있던 폴더의 최근 메일 머리글을 받아 앱이 고르고,
    /// 서버 검색(SEARCH HEADER)으로 더 오래된 것도 찾는다. iCloud는 머리글 검색에 답하지 않을 때가 있어 둘 다 쓴다.
    func conversation(id: String) async throws -> [MailMessage] {
        guard let conv = IMAP.parseConversationID(id), conv.account == accountID else { return [] }
        if kinds.isEmpty { _ = try await folders() }
        // 받은 편지함·보낸 편지함·보관의 최근 메일 머리글(미리 받아 5분 기억)에서 같은 대화를 고른다: 대개 서버에 묻지 않는다
        var paths = ["INBOX"] + kinds.filter { ["sentitems", "archive"].contains($0.value) }.map(\.key)  // l10n: data
        for path in recentMemo.keys where !paths.contains(path) && recentMemo[path]?.list.contains(where: { $0.conversationId == id }) == true {
            paths.append(path)   // 목록에서 이 대화를 본 다른 폴더
        }
        let scans = paths.map { path in Task { await self.recent(path) } }
        var all: [MailMessage] = []
        for task in scans { all += await task.value.filter { $0.conversationId == id } }
        // Gmail: 전체 보관함에서 대화 번호로 더 오래된 메일도 (한 번 묻는다). 같은 메일은 받은·보낸 편지함 것을 남긴다.
        if conv.root.hasPrefix("gm-"), let thread = Int(conv.root.dropFirst(3)), let allMailPath,
           let uids = try? await searchUIDs(path: allMailPath, criteria: [.text("X-GM-THRID \(thread)")]), !uids.isEmpty {
            all += (try? await fetch(path: allMailPath, uids: Array(uids.suffix(200)))) ?? []
        }
        return Self.uniqueByMessageID(all)
    }

    /// 폴더의 최근 메일 요약 300통 (대화 찾기용). 5분 기억하고, 새 메일 알림(IDLE)·보내기 때 지운다.
    private var recentMemo: [String: (at: Date, list: [MailMessage])] = [:]

    /// 대화 찾기에 쓸 머리글을 미리 받아 둔다 (메일을 처음 열 때 기다리지 않게)
    private func warmRecent() {
        let paths = ["INBOX"] + kinds.filter { ["sentitems", "archive"].contains($0.value) }.map(\.key)  // l10n: data
        for path in paths where recentMemo[path].map({ Date().timeIntervalSince($0.at) > 240 }) ?? true {
            Task { _ = await self.recent(path) }
        }
    }

    private func recent(_ path: String) async -> [MailMessage] {
        if let m = recentMemo[path], Date().timeIntervalSince(m.at) < 300 { return m.list }
        guard let result = try? await latest(in: path, count: 300) else { return recentMemo[path]?.list ?? [] }
        let list = summaries(result.reply, path: path)
        recentMemo[path] = (Date(), list)
        return list
    }

    // MARK: 표시

    private func store(_ id: String, _ change: String) async throws {
        let (path, uid) = try parts(id)
        _ = try await run(select: path, "UID STORE \(uid) \(change)")
    }

    func setRead(id: String, read: Bool) async throws {
        try await store(id, read ? "+FLAGS.SILENT (\\Seen)" : "-FLAGS.SILENT (\\Seen)")
    }

    /// 여러 통 (1.0.2): 폴더마다 UID 목록 하나로 STORE 한 번 (한 명령에 500통까지).
    func setRead(ids: [String], read: Bool) async throws -> [String] {
        var byPath: [String: [(id: String, uid: Int)]] = [:]
        var order: [String] = []
        var single: [String] = []
        for id in ids {
            // 옮긴 뒤 UID를 아직 모르는 메일 등은 한 통씩
            guard let (path, uid) = try? parts(id), uid > 0 else { single.append(id); continue }
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: []].append((id, uid))
        }
        var done: [String] = []
        var lastError: Error?
        let change = read ? "+FLAGS.SILENT (\\Seen)" : "-FLAGS.SILENT (\\Seen)"
        for path in order {
            let items = byPath[path] ?? []
            for start in stride(from: 0, to: items.count, by: 500) {
                let slice = items[start..<min(start + 500, items.count)]
                do {
                    _ = try await run(select: path, "UID STORE \(slice.map { String($0.uid) }.joined(separator: ",")) \(change)")
                    done += slice.map(\.id)
                } catch {
                    lastError = error
                }
            }
        }
        if !single.isEmpty {
            do { done += try await setReadOneByOne(ids: single, read: read) } catch { lastError = error }
        }
        if done.isEmpty, let lastError { throw lastError }
        return done
    }

    func setFlag(id: String, flagged: Bool) async throws {
        try await store(id, flagged ? "+FLAGS.SILENT (\\Flagged)" : "-FLAGS.SILENT (\\Flagged)")
    }

    func setImportance(id: String, importance: String) async throws { throw IMAPError.unsupported }

    // MARK: 옮기기·복사·지우기

    func move(id: String, to destination: String) async throws -> String {
        let (path, givenUID) = try parts(id)
        var uid = givenUID
        // 옮긴 뒤 아직 UID를 찾지 않은 메일 (⌘Z): 그 폴더에서 Message-ID로 찾는다
        if uid < 0 {
            guard let header = headerMemo[id], let found = await findUID(path: path, messageID: header) else { throw Self.notFound }
            uid = found
            headerMemo[IMAP.messageID(account: accountID, path: path, uid: found)] = header
        }
        let currentID = IMAP.messageID(account: accountID, path: path, uid: uid)
        let target = try await folderPath(destination)
        if target == path {
            // 휴지통 안에서 지우기: 아주 지운다
            if kinds[path] == "deleteditems" {
                _ = try await run(select: path, "UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
                _ = try? await run(select: path, "UID EXPUNGE \(uid)")
            }
            return currentID
        }
        // 옮긴 뒤 새 UID를 찾으려고 Message-ID를 먼저 읽는다 (서버의 COPYUID는 없거나 믿기 어려울 때가 있다)
        var header = headerMemo[currentID]
        if header == nil { header = await headerMessageID(path: path, uid: uid) }
        let reply: IMAPReply
        do {
            reply = try await run(select: path, "UID MOVE \(uid) " + IMAP.quote(IMAP.encodeFolderName(target)))
        } catch IMAPError.server {
            // MOVE가 없는 서버: 복사하고 지운다
            reply = try await run(select: path, "UID COPY \(uid) " + IMAP.quote(IMAP.encodeFolderName(target)))
            _ = try await run(select: path, "UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            _ = try? await run(select: path, "UID EXPUNGE \(uid)")
        }
        // 새 UID는 지금 찾지 않는다 (지우기가 서버를 한 번 더 기다리지 않게): 임시 id를 주고 ⌘Z 때 Message-ID로 찾는다
        if let header {
            pendingCounter -= 1
            let placeholder = IMAP.messageID(account: accountID, path: target, uid: pendingCounter)
            headerMemo[placeholder] = header
            return placeholder
        }
        return newID(reply, target: target) ?? IMAP.folderID(account: accountID, path: target)
    }

    /// 메일의 Message-ID 머리글
    private func headerMessageID(path: String, uid: Int) async -> String? {
        guard let reply = try? await run(select: path, "UID FETCH \(uid) (UID ENVELOPE)"),
              let items = reply.untagged.compactMap(IMAP.fetchItems).first(where: { $0["UID"]?.int == uid }),
              let id = items["ENVELOPE"].flatMap(IMAP.envelope)?.messageID, !id.isEmpty else { return nil }
        return id
    }

    /// 폴더에서 Message-ID가 같은 메일의 UID (여럿이면 가장 최근에 들어온 것)
    private func findUID(path: String, messageID: String) async -> Int? {
        try? await searchUIDs(path: path, criteria: [.text("HEADER Message-ID "), .literalOrQuoted(messageID)]).last
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
        let target = try await folderPath(destination)
        _ = try await run(select: path, "UID COPY \(uid) " + IMAP.quote(IMAP.encodeFolderName(target)))
    }

    /// 휴지통이 아니면 휴지통으로, 휴지통 안이면 아주 지운다.
    func deleteMessage(id: String) async throws {
        let (path, uid) = try parts(id)
        if kinds.isEmpty { _ = try? await folders() }
        if let trash = trashPath, trash != path {
            _ = try await move(id: id, to: IMAP.folderID(account: accountID, path: trash))
            return
        }
        _ = try await run(select: path, "UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        _ = try? await run(select: path, "UID EXPUNGE \(uid)")
    }

    // MARK: 보내기·초안 (2단계)

    /// SMTP로 보내고, 보낸 편지함에 사본을 둔다. Gmail은 서버가 알아서 보낸 편지함에 넣으므로 두지 않는다.
    func sendMIME(_ mime: Data) async throws {
        try await smtp.send(mime, from: config.email)
        guard config.provider != .gmail else { return }
        if kinds.isEmpty { _ = try? await folders() }
        guard let sent = kinds.first(where: { $0.value == "sentitems" })?.key else { return }
        // 보낸 것은 이미 갔다: 사본 저장이 실패해도 보내기는 성공으로 둔다
        _ = try? await append(mime, to: sent, flags: "(\\Seen)")
        recentMemo[sent] = nil   // 방금 보낸 답장이 대화 내역에 바로 들어가게
    }

    /// 임시 보관함에 새 초안을 두고(\Draft), 예전 초안은 지운다. 새 초안 id.
    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String {
        if kinds.isEmpty { _ = try await folders() }
        guard let drafts = kinds.first(where: { $0.value == "drafts" })?.key else { throw IMAPError.missingFolder("drafts") }
        let reply = try await append(mime, to: drafts, flags: "(\\Seen \\Draft)")
        if let oldID, let old = try? parts(oldID), old.uid > 0 {
            _ = try? await run(select: old.path, "UID STORE \(old.uid) +FLAGS.SILENT (\\Deleted)")
            _ = try? await run(select: old.path, "UID EXPUNGE \(old.uid)")
        }
        // 새 UID: APPENDUID (RFC 4315), 없으면 Message-ID로 찾는다
        if let uid = appendUID(reply) { return IMAP.messageID(account: accountID, path: drafts, uid: uid) }
        if let header = SMTP.messageID(mime), let uid = await findUID(path: drafts, messageID: header) {
            return IMAP.messageID(account: accountID, path: drafts, uid: uid)
        }
        throw IMAPError.server("APPEND")
    }

    private func append(_ mime: Data, to path: String, flags: String) async throws -> IMAPReply {
        try await run([.text("APPEND " + IMAP.quote(IMAP.encodeFolderName(path)) + " " + flags + " "), .literal(mime)])
    }

    /// "[APPENDUID <uidvalidity> <uid>]"
    private func appendUID(_ reply: IMAPReply) -> Int? {
        guard let r = reply.text.range(of: "[APPENDUID ", options: .caseInsensitive) else { return nil }
        let fields = reply.text[r.upperBound...].split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return Int(fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "]")))
    }
    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws { throw IMAPError.unsupported }
    func sendDraft(id: String) async throws { throw IMAPError.unsupported }
    func scheduleDraft(id: String, at date: Date) async throws { throw IMAPError.unsupported }

    // MARK: Exchange에만 있는 기능

    // MARK: 회의 초대 (.ics, 1.0.3)

    /// 연 초대 메일의 일정 (일정 id → 초대)
    private var inviteMemo: [String: ICSInvite] = [:]
    private var me: [String] { [config.email, config.username].filter { !$0.isEmpty } }

    /// 주최자에게 답장(METHOD:REPLY)을 보낸다. 보낸 편지함에는 두지 않는다 (맥 Mail·Outlook처럼).
    func respond(toEvent eventID: String, with response: MeetingResponse) async throws {
        let invite = try await invite(eventID)
        let mine = invite.attendees.first { a in me.contains { $0.lowercased() == a.email.lowercased() } }
        let address = MailAddress(name: config.name.isEmpty ? mine?.name : config.name, address: mine?.email ?? config.email)
        guard let mime = invite.replyMIME(from: address, response: response) else {
            throw IMAPError.server(L("초대에 주최자 주소가 없어 답할 수 없습니다."))
        }
        try await smtp.send(mime, from: config.email)
        Self.saveResponse(eventID, response.graphValue)
    }

    func event(id: String) async throws -> MailEvent {
        let invite = try await invite(id)
        return invite.mailEvent(id: id, response: Self.savedResponse(id) ?? invite.myResponse(me: me))
    }

    func meetingCheck(eventID: String) async throws -> MeetingCheck { throw IMAPError.unsupported }

    /// 기억한 초대, 없으면(앱을 다시 켠 뒤) 그 메일을 다시 읽는다
    private func invite(_ eventID: String) async throws -> ICSInvite {
        if let i = inviteMemo[eventID] { return i }
        if let messageID = Self.inviteMessages[eventID]?["message"] {
            _ = try await message(id: messageID)
            if let i = inviteMemo[eventID] { return i }
        }
        throw Self.notFound
    }

    /// 일정 id → {message: 메일 id, response: 내 답}. 초대 메일을 다시 열거나 앱을 다시 켜도 내 답이 보이게.
    private static let invitesKey = "ics.invites"
    private static var inviteMessages: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: invitesKey) as? [String: [String: String]] ?? [:] }
        set {
            // 오래된 것부터 지워 200개만 둔다
            var v = newValue
            if v.count > 200 { for k in v.keys.sorted().prefix(v.count - 200) { v[k] = nil } }
            UserDefaults.standard.set(v, forKey: invitesKey)
        }
    }
    private static func rememberInvite(_ eventID: String, messageID: String) {
        guard inviteMessages[eventID]?["message"] != messageID else { return }
        inviteMessages[eventID, default: [:]]["message"] = messageID
    }
    private static func savedResponse(_ eventID: String) -> String? { inviteMessages[eventID]?["response"] }
    private static func saveResponse(_ eventID: String, _ value: String) { inviteMessages[eventID, default: [:]]["response"] = value }
    func rules() async throws -> [MessageRule] { [] }
    func createRule(_ rule: MessageRule) async throws -> MessageRule { throw IMAPError.unsupported }
    func setRule(id: String, enabled: Bool) async throws { throw IMAPError.unsupported }
    func deleteRule(id: String) async throws { throw IMAPError.unsupported }
    func automaticReplies() async throws -> AutomaticReplies { throw IMAPError.unsupported }
    func setAutomaticReplies(_ settings: AutomaticReplies) async throws { throw IMAPError.unsupported }
}
