import ExchangeMailKit
import Foundation

/// 초안 목록에 보일 요약. Graph는 MIME에서 읽으므로 쓰지 않고, 데모 서비스가 쓴다.
struct DraftPreview {
    var subject: String
    var to: [MailAddress]
    var cc: [MailAddress]
    var bodyHTML: String
}

struct MessagePage {
    var messages: [MailMessage]
    var nextLink: String?
}

/// 메일 서버와의 대화. 실제 계정은 GraphMailService, 데모·테스트는 DemoMailService.
protocol MailService: AnyObject {
    func folders() async throws -> [MailFolder]
    func messages(folderID: String, search: String?) async throws -> MessagePage
    func nextPage(_ link: String) async throws -> MessagePage
    func message(id: String) async throws -> MailMessage
    func attachments(messageID: String) async throws -> [FileAttachment]
    func setRead(id: String, read: Bool) async throws
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
}

struct GraphError: LocalizedError {
    let status: Int
    let code: String?
    let message: String

    var errorDescription: String? {
        switch status {
        case 401: "Microsoft 계정 인증이 거절되었습니다. 다시 로그인하세요."
        case 403: "이 작업에 필요한 권한이 없습니다 (Mail.ReadWrite, Mail.Send). 관리자 동의가 필요할 수 있습니다."
        case 413: "메일이 너무 큽니다. 조직의 메일 크기 한도를 넘었을 수 있습니다."
        case 429: "요청이 너무 많습니다. 잠시 뒤 다시 시도하세요."
        default:
            code == "ErrorMessageSizeExceeded"
                ? "메일이 조직의 크기 한도를 넘었습니다. 첨부를 줄이거나 OneDrive 링크로 보내세요."
                : "메일 서버 오류 (\(status)): \(message)"
        }
    }
}

/// Microsoft Graph 메일 API.
final class GraphMailService: MailService {
    private let auth: GraphAuth
    private let base = "https://graph.microsoft.com/v1.0"
    private let decoder = GraphJSON.decoder()
    /// 잘 알려진 폴더 id → 이름 (inbox 등). 언어와 상관없이 폴더를 알아보려고 한 번만 묻는다.
    private var wellKnownIDs: [String: String]?

    init(auth: GraphAuth) {
        self.auth = auth
    }

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
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let e = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw GraphError(status: http.statusCode, code: e?.error.code,
                             message: e?.error.message ?? String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: 읽기

    func folders() async throws -> [MailFolder] {
        let ids = await loadWellKnownIDs()
        let data = try await request("GET", "/me/mailFolders",
                                     query: ["$top": "100", "$select": "id,displayName,unreadItemCount,totalItemCount"])
        return try decoder.decode(GraphList<MailFolder>.self, from: data).value.map { f in
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
            if let data = try? await request("GET", "/me/mailFolders/\(name)", query: ["$select": "id"]),
               let f = try? decoder.decode(IDOnly.self, from: data) {
                map[f.id] = name
            }
        }
        wellKnownIDs = map
        return map
    }

    func messages(folderID: String, search: String?) async throws -> MessagePage {
        let r = GraphQuery.messageList(search: search)
        let data = try await request("GET", "/me/mailFolders/\(folderID)/messages", query: r.query, headers: r.headers)
        let list = try decoder.decode(GraphList<MailMessage>.self, from: data)
        return MessagePage(messages: list.value, nextLink: list.nextLink)
    }

    func nextPage(_ link: String) async throws -> MessagePage {
        let headers = link.contains("%24search") || link.contains("$search") ? ["ConsistencyLevel": "eventual"] : [:]
        let data = try await request("GET", link, headers: headers)
        let list = try decoder.decode(GraphList<MailMessage>.self, from: data)
        return MessagePage(messages: list.value, nextLink: list.nextLink)
    }

    func message(id: String) async throws -> MailMessage {
        let data = try await request("GET", "/me/messages/\(id)", query: ["$select": GraphQuery.detailSelect],
                                     headers: ["Prefer": "outlook.body-content-type=\"html\""])
        return try decoder.decode(MailMessage.self, from: data)
    }

    func attachments(messageID: String) async throws -> [FileAttachment] {
        let data = try await request("GET", "/me/messages/\(messageID)/attachments")
        return try decoder.decode(GraphList<FileAttachment>.self, from: data).value
    }

    // MARK: 바꾸기

    func setRead(id: String, read: Bool) async throws {
        _ = try await request("PATCH", "/me/messages/\(id)", body: try json(["isRead": read]))
    }

    func move(id: String, to destination: String) async throws -> String {
        struct IDOnly: Decodable { let id: String }
        let data = try await request("POST", "/me/messages/\(id)/move", body: try json(["destinationId": destination]))
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
        _ = try await request("DELETE", "/me/messages/\(id)")
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
        let data = try await request("POST", "/me/messages/\(id)/attachments/createUploadSession",
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

    func sendDraft(id: String) async throws {
        // 본문이 없는 POST도 Content-Length: 0이 있어야 한다.
        _ = try await request("POST", "/me/messages/\(id)/send", body: Data())
    }
}
