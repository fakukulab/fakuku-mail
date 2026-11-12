import ExchangeMailKit
import Foundation

/// 초안 목록에 보일 요약. Graph는 MIME에서 읽으므로 쓰지 않고, 데모 서비스가 쓴다.
struct DraftPreview {
    var subject: String
    var to: [MailAddress]
    var cc: [MailAddress]
    var bodyHTML: String
}

/// 백그라운드(캐시 저장)로 넘기므로 메인 액터에 묶지 않는다.
nonisolated struct MessagePage: Sendable {
    var messages: [MailMessage]
    var nextLink: String?
    /// 필터를 서버가 걸었는지 (아니면 앱이 다 건다: 검색 중, 오프라인 캐시, 데모)
    var serverFiltered = true
}

extension MailService {
    /// 필터 없이 최근 순 (예전 호출과 셀프 테스트)
    func messages(folderID: String, search: String?) async throws -> MessagePage {
        try await messages(folderID: folderID, search: search, filter: nil, oldestFirst: false)
    }

    /// 묶어 보낼 방법이 없는 서비스(데모): 한 통씩 차례로.
    func setRead(ids: [String], read: Bool) async throws -> [String] {
        try await setReadOneByOne(ids: ids, read: read)
    }

    func setReadOneByOne(ids: [String], read: Bool) async throws -> [String] {
        var done: [String] = []
        var lastError: Error?
        for id in ids {
            do {
                try await setRead(id: id, read: read)
                done.append(id)
            } catch {
                lastError = error
            }
        }
        if done.isEmpty, let lastError { throw lastError }
        return done
    }
}

/// 메일 서버와의 대화. 실제 계정은 GraphMailService, 데모·테스트는 DemoMailService.
protocol MailService: AnyObject {
    func folders() async throws -> [MailFolder]
    /// 폴더 목록. `filter`는 서버에서 걸 수 있는 부분만 서버가 건다 (S-041), `oldestFirst`는 날짜 오름차순 (S-042).
    func messages(folderID: String, search: String?, filter: MailFilter?, oldestFirst: Bool) async throws -> MessagePage
    /// Outlook 범주 이름 (S-041)
    func categories() async throws -> [String]
    func nextPage(_ link: String) async throws -> MessagePage
    func message(id: String) async throws -> MailMessage
    func attachments(messageID: String) async throws -> [FileAttachment]
    /// 첨부 하나의 내용 (`$value`). 목록에 내용이 빠진 큰 파일, 첨부된 메일(.eml)에 쓴다.
    func attachmentContent(messageID: String, attachmentID: String) async throws -> Data
    func setRead(id: String, read: Bool) async throws
    /// 여러 통을 한 번에 읽음·읽지 않음으로 (1.0.2). 바뀐 메일 id를 돌려준다: 일부가 실패해도 나머지는 바꾼다.
    /// 하나도 못 바꿨으면 오류를 던진다.
    func setRead(ids: [String], read: Bool) async throws -> [String]
    /// 옮긴 뒤의 새 메시지 id를 돌려준다 (Graph는 옮기면 id가 바뀐다).
    func move(id: String, to destination: String) async throws -> String
    /// 보정이 끝난 MIME을 그대로 보낸다.
    func sendMIME(_ mime: Data) async throws
    /// MIME을 임시 보관함에 새 초안으로 저장하고, `replacing`이 있으면 그 초안을 지운다. 새 초안 id (S-022).
    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String
    /// 메시지를 지운다 (초안 버리기, 보낸 뒤 초안 정리).
    func deleteMessage(id: String) async throws
    /// 큰 첨부를 초안에 조각으로 올린다 (S-023). `progress`는 0...1.
    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws
    /// 초안을 보낸다 (S-023).
    func sendDraft(id: String) async throws
    /// 대화의 모든 메일 (모든 폴더, 본문 없음). 순서는 정하지 않는다 (S-025).
    func conversation(id: String) async throws -> [MailMessage]
    /// 깃발 달기·떼기 (S-029)
    func setFlag(id: String, flagged: Bool) async throws
    /// 다른 폴더에 복사한다 (M17, 메시지 > 다음으로 복사)
    func copy(id: String, to destination: String) async throws
    /// 우선 순위: low, normal, high (M17)
    func setImportance(id: String, importance: String) async throws
    /// 원본 MIME (RFC 822). 원본 보기와 첨부 파일로 전달에 쓴다 (M17)
    func mimeContent(id: String) async throws -> Data
    /// 깃발 단 메일, 모든 폴더, 최근 순 (S-029)
    func flaggedMessages() async throws -> MessagePage
    /// 사서함 전체 검색 (S-033). 결과에는 parentFolderId가 있다.
    func searchAll(_ text: String) async throws -> MessagePage
    /// 스마트 메일상자 (S-046): `folderID`가 nil이면 모든 폴더. 최근 순. `filter`는 Graph `$filter`.
    func collectMessages(folderID: String?, filter: String?) async throws -> MessagePage
    /// 한 사람이 보낸 메일, 모든 폴더, 최근 순 (S-045 VIP)
    func messages(fromSender address: String) async throws -> MessagePage
    /// 폴더 만들기·이름 바꾸기·지우기 (S-031). `parentID`가 nil이면 맨 위에 만든다.
    func createFolder(name: String, parentID: String?) async throws -> MailFolder
    func renameFolder(id: String, name: String) async throws
    func deleteFolder(id: String) async throws
    /// 초안에 지연 발송 시각을 붙인다 (S-037). 그 뒤 sendDraft로 보내면 Exchange가 그 시각에 보낸다.
    func scheduleDraft(id: String, at date: Date) async throws
    /// 회의 초대에 답한다 (S-038, Calendars.ReadWrite)
    func respond(toEvent eventID: String, with response: MeetingResponse) async throws
    /// 일정을 서버에서 다시 읽는다 (응답이 실제로 반영됐는지 확인)
    func event(id: String) async throws -> MailEvent
    /// 응답한 회의가 실제 일정(캘린더 보기)에 있는지, 같은 회의의 다른 일정이 있는지 (S-038)
    func meetingCheck(eventID: String) async throws -> MeetingCheck
    /// 받은 편지함 서버 규칙 (S-039, MailboxSettings.ReadWrite)
    func rules() async throws -> [MessageRule]
    func createRule(_ rule: MessageRule) async throws -> MessageRule
    func setRule(id: String, enabled: Bool) async throws
    func deleteRule(id: String) async throws
    /// 보낸 편지함의 메일을 회수한다 (S-071, Exchange Online 클라우드 메시지 회수). 결과는 회수 보고서 메일로 온다.
    func recall(id: String) async throws
    /// 부재중 자동 응답 (S-040)
    func automaticReplies() async throws -> AutomaticReplies
    func setAutomaticReplies(_ settings: AutomaticReplies) async throws
}

struct GraphError: LocalizedError {
    let status: Int
    let code: String?
    let message: String

    var errorDescription: String? {
        switch status {
        case 401: L("Microsoft 계정 인증이 거절되었습니다. 다시 로그인하세요.")
        case 403: L("이 작업에 필요한 권한이 없습니다 (Mail.ReadWrite, Mail.Send). 관리자 동의가 필요할 수 있습니다.")
        case 404: L("서버에서 찾을 수 없습니다. 다른 기기나 규칙이 메일을 옮기거나 지웠을 수 있습니다. 목록을 새로 고쳐 주세요.")
        case 413: L("메일이 너무 큽니다. 조직의 메일 크기 한도를 넘었을 수 있습니다.")
        case 429: L("요청이 너무 많습니다. 잠시 뒤 다시 시도하세요.")
        default:
            code == "ErrorMessageSizeExceeded"
                ? L("메일이 조직의 크기 한도를 넘었습니다. 첨부를 줄이거나 OneDrive 링크로 보내세요.")
                : L("메일 서버 오류 (\(status)): \(message)")
        }
    }
}

/// Microsoft Graph 메일 API.
final class GraphMailService: MailService {
    private let auth: GraphAuth
    private let base = "https://graph.microsoft.com/v1.0"
    private let decoder = GraphJSON.decoder()

    /// 메일 목록·본문·첨부처럼 큰 응답은 메인 스레드 밖에서 해석한다: 큰 메일을 열 때 화면이 멈추지 않게.
    private func decodedOffMain<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try GraphJSON.decoder().decode(T.self, from: data) }.value
    }
    /// 잘 알려진 폴더 id → 이름 (inbox 등). 언어와 상관없이 폴더를 알아보려고 한 번만 묻는다.
    private var wellKnownIDs: [String: String]?

    init(auth: GraphAuth) {
        self.auth = auth
    }

    /// 사서함 하나에 동시에 4개 요청까지 (Exchange 한도). 모든 Graph 요청이 이 관문을 지난다.
    static let gate = RequestGate(limit: 4)

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let code: String?; let message: String? }
        let error: Inner
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         body: Data? = nil, contentType: String = "application/json",
                         headers: [String: String] = [:]) async throws -> Data {
        guard var c = URLComponents(string: path.hasPrefix("http") ? path : base + path) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty {
            c.queryItems = (c.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents는 +를 그대로 두는데, 서버는 공백으로 읽을 수 있다 (base64 대화 id가 깨짐).
            c.percentEncodedQuery = QueryEncoding.fixPlus(c.percentEncodedQuery)
        }
        guard let url = c.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        // 서버가 잠시 막으면(429, 503) 알려 준 시간(Retry-After)만큼 쉬고 세 번까지 다시 보낸다.
        // 막힌 요청은 처리되지 않으므로 다시 보내도 두 번 처리되지 않는다.
        var attempt = 0
        while true {
            await Self.gate.acquire()
            let result: (Data, URLResponse)
            do {
                result = try await URLSession.shared.data(for: req)
            } catch {
                Self.gate.release()
                throw error
            }
            Self.gate.release()
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 429 || http.statusCode == 503 {
                let advised = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                GraphThrottle.note(retryAfter: advised ?? 0)
                if attempt < 3 {
                    let wait = min(advised ?? pow(2, Double(attempt + 1)), 30)
                    try await Task.sleep(for: .seconds(wait))
                    attempt += 1
                    continue
                }
            }
            guard (200..<300).contains(http.statusCode) else {
                let e = try? JSONDecoder().decode(ErrorBody.self, from: data)
                throw GraphError(status: http.statusCode, code: e?.error.code,
                                 message: e?.error.message ?? String(decoding: data, as: UTF8.self))
            }
            return data
        }
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: 읽기

    func folders() async throws -> [MailFolder] {
        let ids = await loadWellKnownIDs()
        let data = try await request("GET", "/me/mailFolders",
                                     query: ["$top": "100", "$select": GraphQuery.folderSelect])
        var all = try decoder.decode(GraphList<MailFolder>.self, from: data).value
        // 하위 폴더 (S-031): childFolderCount가 있는 폴더만, 4단계까지 내려간다.
        var queue = all.filter { ($0.childFolderCount ?? 0) > 0 }.map { ($0.id, 1) }
        while !queue.isEmpty {
            let (parentID, level) = queue.removeFirst()
            let childData = try await request("GET", "/me/mailFolders/\(GraphPath.segment(parentID))/childFolders",
                                              query: ["$top": "100", "$select": GraphQuery.folderSelect])
            let children = try decoder.decode(GraphList<MailFolder>.self, from: childData).value
            all += children
            if level < 4 { queue += children.filter { ($0.childFolderCount ?? 0) > 0 }.map { ($0.id, level + 1) } }
        }
        return all.map { f in
            var f = f
            f.wellKnownName = ids[f.id]
            return f
        }
    }

    private func loadWellKnownIDs() async -> [String: String] {
        if let wellKnownIDs { return wellKnownIDs }
        struct IDOnly: Decodable { let id: String }
        var map: [String: String] = [:]
        for name in FolderOrder.wellKnown {
            // 보관 폴더가 없는 사서함도 있다. 실패한 이름은 건너뛴다.
            if let data = try? await request("GET", "/me/mailFolders/\(GraphPath.segment(name))", query: ["$select": "id"]),
               let f = try? decoder.decode(IDOnly.self, from: data) {
                map[f.id] = name
            }
        }
        wellKnownIDs = map
        return map
    }

    func messages(folderID: String, search: String?, filter: MailFilter?, oldestFirst: Bool) async throws -> MessagePage {
        let searching = !(search ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let r = GraphQuery.messageList(search: search, filter: filter?.graphFilter(), oldestFirst: oldestFirst)
        let data = try await request("GET", "/me/mailFolders/\(GraphPath.segment(folderID))/messages", query: r.query, headers: r.headers)
        let list = try await decodedOffMain(GraphList<MailMessage>.self, from: data)
        return MessagePage(messages: list.value, nextLink: list.nextLink, serverFiltered: !searching)
    }

    func categories() async throws -> [String] {
        let data = try await request("GET", "/me/outlook/masterCategories")
        return try decoder.decode(GraphList<OutlookCategory>.self, from: data).value.map { $0.displayName }
    }

    func nextPage(_ link: String) async throws -> MessagePage {
        let headers = link.contains("%24search") || link.contains("$search") ? ["ConsistencyLevel": "eventual"] : [:]
        let data = try await request("GET", link, headers: headers)
        let list = try await decodedOffMain(GraphList<MailMessage>.self, from: data)
        return MessagePage(messages: list.value, nextLink: list.nextLink)
    }

    func message(id: String) async throws -> MailMessage {
        let data = try await request("GET", "/me/messages/\(GraphPath.segment(id))", query: ["$select": GraphQuery.detailSelect],
                                     headers: ["Prefer": "outlook.body-content-type=\"html\""])
        var m = try await decodedOffMain(MailMessage.self, from: data)
        // 회의 초대면 일정도 가져온다 (S-038). 보통 메일에는 이 확장을 쓰지 않는다.
        if m.isMeetingRequest {
            let eventData = try? await request("GET", "/me/messages/\(GraphPath.segment(id))", query: [
                "$select": "id",
                "$expand": "microsoft.graph.eventMessage/event($select=id,subject,start,end,location,isAllDay,responseStatus)",
            ])
            m.event = eventData.flatMap { try? decoder.decode(MailMessage.self, from: $0) }?.event
        }
        return m
    }

    /// 첨부 내용 요청을 미리 만든다 (토큰이 남아 있을 때만). 메인 스레드 밖에서 그대로 보낼 수 있다 (첨부 끌기).
    func attachmentRequest(messageID: String, attachmentID: String) -> URLRequest? {
        guard let token = auth.cachedAccessToken,
              let url = URL(string: base + "/me/messages/\(GraphPath.segment(messageID))/attachments/\(GraphPath.segment(attachmentID))/$value")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    func attachmentContent(messageID: String, attachmentID: String) async throws -> Data {
        try await request("GET", "/me/messages/\(GraphPath.segment(messageID))/attachments/\(GraphPath.segment(attachmentID))/$value")
    }

    /// 첨부 목록. 내용(contentBytes)은 받지 않는다: 큰 파일까지 다 받으면 메일 하나 여는 데 수 MB가 오간다.
    /// 본문에 들어가는 인라인 그림만 내용을 함께(병렬로) 받는다. 파일은 열거나 저장할 때 받는다 (loadedAttachment).
    func attachments(messageID: String) async throws -> [FileAttachment] {
        let data = try await request("GET", "/me/messages/\(GraphPath.segment(messageID))/attachments",
                                     query: ["$select": "id,name,contentType,size,isInline"])
        var list = try await decodedOffMain(GraphList<FileAttachment>.self, from: data).value
        let inline = list.indices.filter { i in
            let a = list[i]
            return a.isInline == true && (a.odataType ?? "").hasSuffix("fileAttachment")
        }
        guard !inline.isEmpty else { return list }
        // 인라인 그림: contentId와 내용이 필요하다. 하나씩 전체를 받는다 (병렬).
        // 요청을 한꺼번에 띄우고(네트워크는 동시에 진행), 받은 순서대로 해석한다.
        let downloads = inline.map { i in
            let id = list[i].id
            return (i, Task { try? await self.request("GET", "/me/messages/\(GraphPath.segment(messageID))/attachments/\(GraphPath.segment(id))") })
        }
        for (i, task) in downloads {
            if let data = await task.value, let full = try? await decodedOffMain(FileAttachment.self, from: data) {
                list[i] = full
            }
        }
        return list
    }

    // MARK: 바꾸기

    func setRead(id: String, read: Bool) async throws {
        _ = try await request("PATCH", "/me/messages/\(GraphPath.segment(id))", body: try json(["isRead": read]))
    }

    /// 여러 통은 JSON 묶음 요청(`$batch`, 한 번에 20개까지)으로 보낸다 (1.0.2).
    /// 한 통씩 PATCH하면 수백 통에 수백 번 왕복했다. 묶음 안에서 서버가 막은 것(429, 503)은 기다렸다 다시 보낸다.
    func setRead(ids: [String], read: Bool) async throws -> [String] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        if unique.count == 1 {
            try await setRead(id: unique[0], read: read)
            return unique
        }
        var done: [String] = []
        var lastError: Error?
        for chunk in GraphBatch.chunks(unique) {
            var pending = chunk
            var attempt = 0
            while !pending.isEmpty {
                let data: Data
                do {
                    let body = try JSONSerialization.data(withJSONObject: GraphBatch.readRequests(pending, read: read))
                    data = try await request("POST", "/$batch", body: body)
                } catch {
                    lastError = error
                    break
                }
                let result = GraphBatch.parse(data, ids: pending)
                done += result.done
                if let failed = result.failedStatus {
                    lastError = GraphError(status: failed, code: nil, message: L("일부 메일의 읽음 상태를 바꾸지 못했습니다."))
                }
                guard !result.retry.isEmpty else { break }
                guard attempt < 3 else {
                    lastError = GraphError(status: 429, code: nil, message: L("서버가 요청을 잠시 막았습니다. 잠시 뒤 다시 해 보세요."))
                    break
                }
                let wait = min(result.retryAfter ?? pow(2, Double(attempt + 1)), 30)
                GraphThrottle.note(retryAfter: wait)
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
                pending = result.retry
            }
        }
        if done.isEmpty, let lastError { throw lastError }
        return done
    }

    func move(id: String, to destination: String) async throws -> String {
        struct IDOnly: Decodable { let id: String }
        let data = try await request("POST", "/me/messages/\(GraphPath.segment(id))/move", body: try json(["destinationId": destination]))
        return (try? decoder.decode(IDOnly.self, from: data).id) ?? id
    }

    /// Graph는 `Content-Type: text/plain` + base64 MIME 본문을 받는다. 파일명 인코딩이 그대로 보존된다.
    func sendMIME(_ mime: Data) async throws {
        _ = try await request("POST", "/me/sendMail", body: mime.base64EncodedData(), contentType: "text/plain")
    }

    /// `POST /me/messages`에 MIME을 보내면 임시 보관함에 초안이 생긴다. 고치기(PATCH)는 MIME을 받지 않으므로
    /// 새로 만들고 예전 초안을 지운다.
    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String {
        struct IDOnly: Decodable { let id: String }
        let data = try await request("POST", "/me/messages", body: mime.base64EncodedData(), contentType: "text/plain")
        let newID = try decoder.decode(IDOnly.self, from: data).id
        if let oldID, oldID != newID { try? await deleteMessage(id: oldID) }
        return newID
    }

    func deleteMessage(id: String) async throws {
        _ = try await request("DELETE", "/me/messages/\(GraphPath.segment(id))")
    }

    /// 업로드 세션: 세션을 만들고, 받은 uploadUrl에 조각을 PUT한다. uploadUrl은 미리 인증된 주소라
    /// Authorization 헤더를 붙이면 안 된다 (붙이면 401).
    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws {
        struct Session: Decodable { let uploadUrl: String }
        let total = attachment.data.count
        let item: [String: Any] = [
            "attachmentType": "file",
            "name": FilenameEncoder.normalize(attachment.filename),
            "size": total,
            "contentType": attachment.mimeType,
            "isInline": false,
        ]
        let data = try await request("POST", "/me/messages/\(GraphPath.segment(id))/attachments/createUploadSession",
                                     body: try json(["AttachmentItem": item]))
        let session = try decoder.decode(Session.self, from: data)
        guard let url = URL(string: session.uploadUrl) else { throw URLError(.badURL) }

        for range in UploadChunks.ranges(total: total) {
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(UploadChunks.contentRange(range, total: total), forHTTPHeaderField: "Content-Range")
            let chunk = attachment.data.subdata(in: range)
            var attempt = 0
            while true {
                attempt += 1
                do {
                    let (body, response) = try await URLSession.shared.upload(for: req, from: chunk)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard (200..<300).contains(status) else {
                        let e = try? JSONDecoder().decode(ErrorBody.self, from: body)
                        throw GraphError(status: status, code: e?.error.code,
                                         message: e?.error.message ?? String(decoding: body, as: UTF8.self))
                    }
                    break
                } catch let error as GraphError where error.status < 500 {
                    throw error
                } catch {
                    // 네트워크 끊김이나 5xx: 같은 조각을 두 번까지 다시 보낸다.
                    if attempt >= 3 { throw error }
                    try await Task.sleep(for: .seconds(attempt * 2))
                }
            }
            progress(Double(range.upperBound) / Double(total))
        }
    }

    func conversation(id: String) async throws -> [MailMessage] {
        let r = GraphQuery.conversation(id: id)
        let data = try await request("GET", "/me/messages", query: r.query, headers: r.headers)
        return try await decodedOffMain(GraphList<MailMessage>.self, from: data).value
    }

    func setFlag(id: String, flagged: Bool) async throws {
        let body = try JSONEncoder().encode(["flag": flagged ? FollowupFlag.flagged : FollowupFlag.notFlagged])
        _ = try await request("PATCH", "/me/messages/\(GraphPath.segment(id))", body: body)
    }

    func copy(id: String, to destination: String) async throws {
        _ = try await request("POST", "/me/messages/\(GraphPath.segment(id))/copy", body: try json(["destinationId": destination]))
    }

    func setImportance(id: String, importance: String) async throws {
        _ = try await request("PATCH", "/me/messages/\(GraphPath.segment(id))", body: try json(["importance": importance]))
    }

    func mimeContent(id: String) async throws -> Data {
        try await request("GET", "/me/messages/\(GraphPath.segment(id))/$value")
    }

    func searchAll(_ text: String) async throws -> MessagePage {
        let r = GraphQuery.searchAll(text)
        let data = try await request("GET", "/me/messages", query: r.query, headers: r.headers)
        let list = try await decodedOffMain(GraphList<MailMessage>.self, from: data)
        return MessagePage(messages: list.value, nextLink: list.nextLink)
    }

    func collectMessages(folderID: String?, filter: String?) async throws -> MessagePage {
        let r = folderID == nil
            ? GraphQuery.collect(filter: filter)
            : GraphQuery.messageList(search: nil, filter: filter, oldestFirst: false, top: 100)
        let path = folderID.map { "/me/mailFolders/\(GraphPath.segment($0))/messages" } ?? "/me/messages"
        let data = try await request("GET", path, query: r.query, headers: r.headers)
        let list = try await decodedOffMain(GraphList<MailMessage>.self, from: data)
        let sorted = list.value.sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        return MessagePage(messages: sorted, nextLink: list.nextLink, serverFiltered: false)
    }

    func messages(fromSender address: String) async throws -> MessagePage {
        // KQL from: 검색. 이름이 비슷한 다른 사람이 섞일 수 있어 주소로 다시 거른다.
        let page = try await searchAll("from:\(address)")
        let mine = page.messages.filter { $0.from?.emailAddress.address?.lowercased() == address.lowercased() }
        return MessagePage(messages: mine.sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) },
                           nextLink: nil, serverFiltered: false)
    }

    func flaggedMessages() async throws -> MessagePage {
        let r = GraphQuery.flagged()
        let data = try await request("GET", "/me/messages", query: r.query, headers: r.headers)
        let list = try await decodedOffMain(GraphList<MailMessage>.self, from: data)
        let sorted = list.value.sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        return MessagePage(messages: sorted, nextLink: nil)
    }

    func scheduleDraft(id: String, at date: Date) async throws {
        _ = try await request("PATCH", "/me/messages/\(GraphPath.segment(id))", body: try json(ScheduledSend.patchBody(sendAt: date)))
    }

    /// 메시지 회수는 Graph beta에만 있다 (2026-11 기준 v1.0에 없음). 본문 없이 POST, 성공하면 202.
    /// https://learn.microsoft.com/graph/api/message-recall
    func recall(id: String) async throws {
        _ = try await request("POST", "https://graph.microsoft.com/beta/me/mailFolders/sentitems/messages/\(GraphPath.segment(id))/recall",
                              headers: ["Content-Length": "0"])
    }

    private let rulesPath = "/me/mailFolders/inbox/messageRules"

    func rules() async throws -> [MessageRule] {
        let data = try await request("GET", rulesPath)
        return try decoder.decode(GraphList<MessageRule>.self, from: data).value
            .sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    }

    func createRule(_ rule: MessageRule) async throws -> MessageRule {
        let data = try await request("POST", rulesPath, body: try json(rule.createBody))
        return try decoder.decode(MessageRule.self, from: data)
    }

    func setRule(id: String, enabled: Bool) async throws {
        _ = try await request("PATCH", "\(rulesPath)/\(GraphPath.segment(id))", body: try json(["isEnabled": enabled]))
    }

    func deleteRule(id: String) async throws {
        _ = try await request("DELETE", "\(rulesPath)/\(GraphPath.segment(id))")
    }

    func automaticReplies() async throws -> AutomaticReplies {
        let data = try await request("GET", "/me/mailboxSettings/automaticRepliesSetting")
        return try decoder.decode(AutomaticReplies.self, from: data)
    }

    func setAutomaticReplies(_ settings: AutomaticReplies) async throws {
        struct Body: Encodable { let automaticRepliesSetting: AutomaticReplies }
        _ = try await request("PATCH", "/me/mailboxSettings", body: try JSONEncoder().encode(Body(automaticRepliesSetting: settings)))
    }

    func event(id: String) async throws -> MailEvent {
        let data = try await request("GET", "/me/events/\(GraphPath.segment(id))",
                                     query: ["$select": "id,subject,start,end,location,isAllDay,responseStatus"])
        return try decoder.decode(MailEvent.self, from: data)
    }

    func meetingCheck(eventID: String) async throws -> MeetingCheck {
        let data = try await request("GET", "/me/events/\(GraphPath.segment(eventID))", query: [
            "$select": "id,iCalUId,isCancelled,webLink,start,end,responseStatus",
            "$expand": "calendar($select=name)",
        ])
        let d = try decoder.decode(EventDetail.self, from: data)
        var found = false
        var viewResponse: String?
        var others: [String] = []
        if let uid = d.iCalUId, let start = d.start?.date, let end = d.end?.date {
            // 회의 앞뒤 하루를 넉넉히 본다 (시간대 차이).
            let f = ISO8601DateFormatter()
            let view = try await request("GET", "/me/calendarView", query: [
                "startDateTime": f.string(from: start.addingTimeInterval(-86_400)),
                "endDateTime": f.string(from: end.addingTimeInterval(86_400)),
                "$select": "id,iCalUId,responseStatus", "$top": "100",
            ])
            let items = try decoder.decode(GraphList<EventRef>.self, from: view).value
            if let match = items.first(where: { $0.iCalUId == uid }) {
                found = true
                viewResponse = match.responseStatus?.response
                if match.id != eventID { others.append(match.id) }
            }
            // 다른 캘린더에 같은 회의가 따로 있는지
            let same = try? await request("GET", "/me/events", query: [
                "$filter": "iCalUId eq '\(uid.replacingOccurrences(of: "'", with: "''"))'", "$select": "id,iCalUId,responseStatus",
            ])
            if let same, let list = try? decoder.decode(GraphList<EventRef>.self, from: same).value {
                for e in list where e.id != eventID && !others.contains(e.id) { others.append(e.id) }
            }
        }
        return MeetingCheck(response: d.responseStatus?.response, calendarName: d.calendar?.name,
                            isCancelled: d.isCancelled ?? false, foundInCalendarView: found,
                            calendarViewResponse: viewResponse, otherEventIDs: others,
                            webLink: d.webLink.flatMap(URL.init(string:)))
    }

    func respond(toEvent eventID: String, with response: MeetingResponse) async throws {
        _ = try await request("POST", "/me/events/\(GraphPath.segment(eventID))/\(response.path)",
                              body: try json(["comment": "", "sendResponse": true]))
    }

    func createFolder(name: String, parentID: String?) async throws -> MailFolder {
        let path = parentID.map { "/me/mailFolders/\(GraphPath.segment($0))/childFolders" } ?? "/me/mailFolders"
        let data = try await request("POST", path, body: try json(["displayName": name]))
        return try decoder.decode(MailFolder.self, from: data)
    }

    func renameFolder(id: String, name: String) async throws {
        _ = try await request("PATCH", "/me/mailFolders/\(GraphPath.segment(id))", body: try json(["displayName": name]))
    }

    /// 폴더를 지우면 Exchange가 지운 편지함으로 옮긴다.
    func deleteFolder(id: String) async throws {
        _ = try await request("DELETE", "/me/mailFolders/\(GraphPath.segment(id))")
    }

    func sendDraft(id: String) async throws {
        // 본문이 없는 POST도 Content-Length: 0이 있어야 한다.
        _ = try await request("POST", "/me/messages/\(GraphPath.segment(id))/send", body: Data())
    }
}
