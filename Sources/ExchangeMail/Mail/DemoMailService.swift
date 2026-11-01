import ExchangeMailKit
import Foundation

/// 로그인 없이 도는 예시 사서함. 스냅숏, 셀프 테스트, 화면 확인용 (APP_SEED=1, APP_STORE in /tmp).
/// 여기 담긴 것은 모두 앱에서 실제로 만들거나 받을 수 있는 것들이다.
final class DemoMailService: MailService {
    static let myAddress = "me@contoso.co.kr"

    /// 셀프 테스트가 네트워크가 끊긴 것처럼 만든다 (S-026).
    var simulateOffline = false

    private func checkOnline() throws {
        if simulateOffline { throw URLError(.notConnectedToInternet) }
    }

    private(set) var folderList: [MailFolder]
    private var store: [String: [MailMessage]]
    private var files: [String: [FileAttachment]] = [:]
    /// 보낸 MIME (셀프 테스트가 읽는다)
    private(set) var sent: [Data] = []
    private var moveCounter = 0

    init() {
        folderList = [
            MailFolder(id: "inbox", displayName: "받은 편지함", wellKnownName: "inbox"),
            MailFolder(id: "drafts", displayName: "임시 보관함", wellKnownName: "drafts"),
            MailFolder(id: "sentitems", displayName: "보낸 편지함", wellKnownName: "sentitems"),
            MailFolder(id: "archive", displayName: "보관", wellKnownName: "archive"),
            MailFolder(id: "junkemail", displayName: "정크 메일", wellKnownName: "junkemail"),
            MailFolder(id: "deleteditems", displayName: "지운 편지함", wellKnownName: "deleteditems"),
            MailFolder(id: "projects", displayName: "프로젝트"),
        ]
        store = [:]
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        func who(_ name: String, _ address: String) -> Recipient { Recipient(name: name, address: address) }
        let me = who("데모 사용자", Self.myAddress)

        store["inbox"] = [
            MailMessage(id: "m1", internetMessageId: "<m1@fabrikam.com>", conversationId: "conv-quote",
                        subject: "[견적] 3분기 장비 견적서 송부드립니다",
                        from: who("김민지", "minji.kim@fabrikam.com"), toRecipients: [me],
                        ccRecipients: [who("박서준", "seojun.park@fabrikam.com")], receivedDateTime: ago(0.5),
                        bodyPreview: "안녕하세요, 요청하신 3분기 장비 견적서를 첨부합니다. 검토 후 회신 부탁드립니다.",
                        isRead: false, hasAttachments: true,
                        body: .init(contentType: "html", content: """
                        <p>안녕하세요, 데모 사용자님.</p><p>요청하신 <b>3분기 장비 견적서</b>를 첨부합니다.<br>\
                        현장 사진도 함께 보내 드립니다.</p><p><img src="cid:site@fabrikam" alt="현장사진.svg"></p>\
                        <p>검토 후 회신 부탁드립니다.</p><p>김민지 드림<br>패브리캄 영업팀</p>
                        """)),
            MailMessage(id: "m2", internetMessageId: "<m2@contoso.co.kr>", subject: "주간 회의록 (11월 첫째 주)",
                        from: who("이도윤", "doyoon.lee@contoso.co.kr"), toRecipients: [me, who("개발팀", "dev@contoso.co.kr")],
                        receivedDateTime: ago(3), bodyPreview: "이번 주 회의 결정 사항을 정리했습니다. 1. 배포 일정 확정 2. 디자인 검토",
                        isRead: false, hasAttachments: false,
                        body: .init(contentType: "html", content: """
                        <p>이번 주 회의 결정 사항입니다.</p><ol><li>배포 일정: 11월 14일 확정</li>\
                        <li>디자인 검토: 목요일 오후 2시</li><li>다음 회의: 11월 8일</li></ol>
                        """)),
            MailMessage(id: "m3", internetMessageId: "<m3@news.example.com>", subject: "11월 업계 소식",
                        from: who("업계 소식", "news@news.example.com"), toRecipients: [me], receivedDateTime: ago(26),
                        bodyPreview: "이번 달 주요 소식을 전해 드립니다.", isRead: true, hasAttachments: false,
                        body: .init(contentType: "html", content: """
                        <p><img src="https://news.example.com/banner.png" alt="배너" width="600"></p>\
                        <h2>11월 업계 소식</h2><p>이번 달 주요 소식을 전해 드립니다. \
                        <a href="https://news.example.com/2024-11">전체 기사 보기</a></p>
                        """)),
            MailMessage(id: "m4", internetMessageId: "<m4@contoso.co.kr>", subject: "휴가 신청 승인 안내",
                        from: who("인사팀", "hr@contoso.co.kr"), toRecipients: [me], receivedDateTime: ago(50),
                        bodyPreview: "신청하신 휴가가 승인되었습니다.", isRead: true, hasAttachments: false,
                        body: .init(contentType: "text", content: "신청하신 휴가(12월 23일~12월 27일)가 승인되었습니다.\n\n인사팀 드림")),
            MailMessage(id: "m5", internetMessageId: "<m5@fabrikam.com>",
                        subject: "RE: 납품 일정 조정 요청 건으로 연락드립니다. 첨부한 일정표를 확인해 주시고 가능한 날짜를 알려 주세요",
                        from: who("박서준", "seojun.park@fabrikam.com"), toRecipients: [me], receivedDateTime: ago(24 * 9),
                        bodyPreview: "말씀하신 대로 일정표를 수정했습니다.", isRead: true, hasAttachments: true,
                        body: .init(contentType: "html", content: "<p>말씀하신 대로 일정표를 수정했습니다. 확인 부탁드립니다.</p>")),
        ]
        store["inbox"]?.append(
            MailMessage(id: "m7", internetMessageId: "<m7@fabrikam.com>", conversationId: "conv-quote",
                        subject: "RE: [견적] 3분기 장비 견적 요청", from: who("김민지", "minji.kim@fabrikam.com"),
                        toRecipients: [me], receivedDateTime: ago(26),
                        bodyPreview: "요청 잘 받았습니다. 내일 중으로 견적서를 보내 드리겠습니다.", isRead: true, hasAttachments: false,
                        body: .init(contentType: "html", content: "<p>요청 잘 받았습니다. 내일 중으로 견적서를 보내 드리겠습니다.</p><p>김민지 드림</p>")))
        store["sentitems"] = [
            MailMessage(id: "s2", internetMessageId: "<s2@contoso.co.kr>", conversationId: "conv-quote",
                        subject: "[견적] 3분기 장비 견적 요청", from: me, toRecipients: [who("김민지", "minji.kim@fabrikam.com")],
                        receivedDateTime: ago(30), bodyPreview: "3분기 장비 견적을 부탁드립니다. 수량은 첨부한 목록과 같습니다.",
                        isRead: true, hasAttachments: false,
                        body: .init(contentType: "html", content: "<p>3분기 장비 견적을 부탁드립니다. 수량은 첨부한 목록과 같습니다.</p>")),
            MailMessage(id: "s1", internetMessageId: "<s1@contoso.co.kr>", subject: "RE: [견적] 2분기 장비 견적서",
                        from: me, toRecipients: [who("김민지", "minji.kim@fabrikam.com")], receivedDateTime: ago(24 * 40),
                        bodyPreview: "견적서 잘 받았습니다. 내부 검토 후 연락드리겠습니다.", isRead: true, hasAttachments: false,
                        body: .init(contentType: "html", content: "<p>견적서 잘 받았습니다. 내부 검토 후 연락드리겠습니다.</p>")),
        ]
        store["archive"] = [
            MailMessage(id: "a1", internetMessageId: "<a1@contoso.co.kr>", subject: "2024년 상반기 실적 보고",
                        from: who("이도윤", "doyoon.lee@contoso.co.kr"), toRecipients: [me], receivedDateTime: ago(24 * 120),
                        bodyPreview: "상반기 실적 보고서를 공유합니다.", isRead: true, hasAttachments: false,
                        body: .init(contentType: "html", content: "<p>상반기 실적 보고서를 공유합니다.</p>")),
        ]
        store["drafts"] = []
        store["junkemail"] = []
        store["deleteditems"] = []
        store["projects"] = []

        files["m1"] = [
            FileAttachment(id: "f1", name: "2024년 3분기 장비 견적서.pdf", contentType: "application/pdf", size: 182_000,
                           isInline: false, contentBytes: Data("%PDF-1.4 demo".utf8).base64EncodedString()),
            FileAttachment(id: "f2", name: "현장사진.svg", contentType: "image/svg+xml", size: 420, isInline: true,
                           contentId: "site@fabrikam", contentBytes: Data(Self.sampleSVG.utf8).base64EncodedString()),
        ]
        files["m5"] = [
            FileAttachment(id: "f3", name: "납품 일정표_수정본.xlsx",
                           contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                           size: 24_000, isInline: false, contentBytes: Data("demo".utf8).base64EncodedString()),
        ]
        recount()
    }

    static let sampleSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="480" height="200" viewBox="0 0 480 200">\
    <rect width="480" height="200" rx="16" fill="#dbe7f5"/><rect x="40" y="110" width="400" height="60" fill="#8fa9c7"/>\
    <polygon points="60,110 160,40 260,110" fill="#5b7fa8"/><circle cx="400" cy="56" r="24" fill="#f5c45b"/></svg>
    """

    /// 데모 서명 두 개와 기본 규칙. 설정 > 서명에서 사람이 만들 수 있는 것과 같다.
    static func seedSignatures(into store: SignatureStore) {
        let logo = "data:image/svg+xml;base64," + Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="96" height="24"><rect width="96" height="24" rx="6" fill="#0a84ff"/>\
        <text x="48" y="17" font-family="Helvetica" font-size="13" fill="#fff" text-anchor="middle">CONTOSO</text></svg>
        """.utf8).base64EncodedString()
        let full = store.add(name: "회사 서명")
        store.update(id: full.id, html: """
        <div style="font-family:'Apple SD Gothic Neo';font-size:13px"><b>데모 사용자</b> · 영업팀 과장<br>\
        <span style="color:#666">콘토소 주식회사 | 02-123-4567</span><br><img src="\(logo)" alt="logo.svg"></div>
        """)
        let short = store.add(name: "간단 서명")
        store.update(id: short.id, html: "<div style=\"font-size:13px\">데모 사용자 드림</div>")
        store.setRule(.new, to: full.id)
        store.setRule(.reply, to: short.id)
        store.setRule(.forward, to: full.id)
    }

    private func recount() {
        for i in folderList.indices {
            let list = store[folderList[i].id] ?? []
            folderList[i].unreadItemCount = list.filter(\.isUnread).count
            folderList[i].totalItemCount = list.count
        }
    }

    private func find(_ id: String) -> (folder: String, index: Int)? {
        for (folder, list) in store {
            if let i = list.firstIndex(where: { $0.id == id }) { return (folder, i) }
        }
        return nil
    }

    // MARK: MailService

    func folders() async throws -> [MailFolder] {
        try checkOnline()
        return folderList
    }

    func messages(folderID: String, search: String?) async throws -> MessagePage {
        try checkOnline()
        var list = (store[folderID] ?? []).sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        if let s = search?.lowercased(), !s.isEmpty {
            list = list.filter { m in
                [m.subject, m.bodyPreview, m.from?.emailAddress.display, m.from?.emailAddress.address]
                    .compactMap { $0?.lowercased() }.contains { $0.contains(s) }
            }
        }
        return MessagePage(messages: list, nextLink: nil)
    }

    func nextPage(_ link: String) async throws -> MessagePage {
        try checkOnline()
        return MessagePage(messages: [], nextLink: nil)
    }

    func message(id: String) async throws -> MailMessage {
        try checkOnline()
        guard let (folder, index) = find(id), let m = store[folder]?[index] else { throw URLError(.fileDoesNotExist) }
        return m
    }

    func attachments(messageID: String) async throws -> [FileAttachment] {
        try checkOnline()
        return files[messageID] ?? []
    }

    func setRead(id: String, read: Bool) async throws {
        try checkOnline()
        guard let (folder, index) = find(id) else { return }
        store[folder]?[index].isRead = read
        recount()
    }

    func move(id: String, to destination: String) async throws -> String {
        try checkOnline()
        guard let (folder, index) = find(id), let m = store[folder]?[index] else { throw URLError(.fileDoesNotExist) }
        let target = folderList.first { $0.id == destination || $0.wellKnownName == destination }?.id ?? destination
        store[folder]?.remove(at: index)
        moveCounter += 1
        // Graph처럼 옮기면 id가 바뀐다.
        var moved = MailMessage(id: "\(m.id.split(separator: "~").first ?? "")~\(moveCounter)", internetMessageId: m.internetMessageId,
                                subject: m.subject, from: m.from, toRecipients: m.toRecipients, ccRecipients: m.ccRecipients,
                                receivedDateTime: m.receivedDateTime, bodyPreview: m.bodyPreview, isRead: m.isRead,
                                hasAttachments: m.hasAttachments, body: m.body)
        moved.conversationId = m.conversationId
        store[target, default: []].append(moved)
        files[moved.id] = files[m.id]
        recount()
        return moved.id
    }

    func sendMIME(_ mime: Data) async throws {
        try checkOnline()
        sent.append(mime)
    }

    private(set) var draftCounter = 0

    func saveDraft(_ mime: Data, preview: DraftPreview, replacing oldID: String?) async throws -> String {
        try checkOnline()
        if let oldID { try? await deleteMessage(id: oldID) }
        draftCounter += 1
        let id = "draft\(draftCounter)"
        func people(_ list: [MailAddress]) -> [Recipient] { list.map { Recipient(name: $0.name, address: $0.address) } }
        let message = MailMessage(id: id, internetMessageId: "<\(id)@contoso.co.kr>", subject: preview.subject,
                                  from: Recipient(name: "데모 사용자", address: Self.myAddress),
                                  toRecipients: people(preview.to), ccRecipients: people(preview.cc),
                                  receivedDateTime: Date(), bodyPreview: HTMLProcessor.plainText(from: preview.bodyHTML),
                                  isRead: true, hasAttachments: false,
                                  body: .init(contentType: "html", content: preview.bodyHTML))
        store["drafts", default: []].append(message)
        recount()
        return id
    }

    /// 데모 받은 편지함에 새 메일이 온 것처럼 넣는다 (셀프 테스트 S-024).
    func deliver(_ message: MailMessage) {
        store["inbox", default: []].append(message)
        recount()
    }

    /// 올린 큰 첨부 (메시지 id, 파일 이름, 크기). 셀프 테스트가 읽는다.
    private(set) var uploaded: [(message: String, name: String, size: Int)] = []
    /// 초안으로 보낸 메시지 id
    private(set) var sentDrafts: [String] = []

    func uploadAttachment(_ attachment: OutgoingAttachment, toMessage id: String,
                          progress: @escaping (Double) -> Void) async throws {
        try checkOnline()
        guard find(id) != nil else { throw URLError(.fileDoesNotExist) }
        let total = attachment.data.count
        for range in UploadChunks.ranges(total: total) {
            progress(Double(range.upperBound) / Double(total))
        }
        uploaded.append((id, FilenameEncoder.normalize(attachment.filename), total))
    }

    func conversation(id: String) async throws -> [MailMessage] {
        try checkOnline()
        store.flatMap { folder, list in
            list.filter { $0.conversationId == id }.map { m -> MailMessage in
                var copy = m
                copy.parentFolderId = folder
                copy.body = nil
                return copy
            }
        }
    }

    func sendDraft(id: String) async throws {
        try checkOnline()
        guard let (folder, index) = find(id), let m = store[folder]?[index] else { throw URLError(.fileDoesNotExist) }
        store[folder]?.remove(at: index)
        store["sentitems", default: []].append(m)
        sentDrafts.append(id)
        recount()
    }

    func deleteMessage(id: String) async throws {
        try checkOnline()
        guard let (folder, index) = find(id) else { return }
        store[folder]?.remove(at: index)
        files[id] = nil
        recount()
    }
}
