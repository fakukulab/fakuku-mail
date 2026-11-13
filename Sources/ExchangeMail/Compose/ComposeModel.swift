import ExchangeMailKit
import Foundation
import Observation

/// 작성 창 하나의 상태와 동작. 화면(ComposeView)과 셀프 테스트가 같이 쓴다.
/// 보내기와 초안 저장(S-022)이 같은 입력 조립(`input()`)을 쓴다.
@Observable
final class ComposeModel {
    let draft: ComposeDraft
    let editor = RichTextController()

    var to = ""
    var cc = ""
    var bcc = ""
    var showBcc = false
    /// 우선 순위: high, normal, low (작성 창 머리글의 ! 메뉴)
    var importance = "normal"
    /// 답장 받을 사람 (보기 > 답장 받을 사람 주소 필드)
    var replyTo = ""
    var subject = ""
    var files: [URL] = []
    var forwarded: [FileAttachment] = []
    var signatureID: UUID?
    /// 보낼 계정 (M23). 작성 창의 보낸 사람 메뉴에서 바꾼다.
    var accountID: String?
    var fixEnabled = true

    private(set) var sending = false
    /// 큰 첨부를 올리는 동안 (S-023): "큰 첨부 올리는 중 1/2"와 전체 진행률 0...1
    private(set) var uploadStatus: String?
    private(set) var uploadFraction: Double?
    private(set) var didSetUp = false

    // 초안 (S-022)
    /// 임시 보관함에 있는 이 메일의 초안 id
    private(set) var savedDraftID: String?
    private(set) var savingDraft = false
    private(set) var lastDraftSave: Date?
    /// 마지막으로 저장한(또는 처음 연) 내용. 지금 내용과 다르면 저장할 것이 있다.
    @ObservationIgnored private var savedFingerprint = ""
    /// 이 Mac에 마지막으로 저장한 내용 (S-072)
    @ObservationIgnored private var localFingerprint = ""
    /// 이 Mac에만 저장되어 있고 서버의 임시 보관함에는 아직 없다 (S-072: 오프라인에 저장했을 때)
    private(set) var savedOnlyOnMac = false
    /// 보냈거나 버렸으면 창을 닫아도 저장하지 않는다.
    private(set) var finished = false
    /// 사람이 본문을 고친 횟수. 웹 편집기는 넣은 HTML을 정리해서 돌려주므로 HTML 문자열로 비교하지 않는다.
    private(set) var bodyRevision = 0
    /// 본문에 지금 들어 있는 서명. 메뉴 값이 이것과 다를 때만 본문을 바꾼다.
    @ObservationIgnored private var appliedSignatureID: UUID?
    var error: String?
    var errorTitle = L("보낼 수 없습니다")

    init(draft: ComposeDraft) {
        self.draft = draft
        savedDraftID = draft.draftMessageID
        // 이 Mac에만 저장된 초안을 이어 쓰면: 서버에 올릴 것이 남아 있다 (손대지 않고 닫아도 사본을 지우지 않게, S-072)
        savedOnlyOnMac = PendingDrafts.load(draft.id) != nil
    }

    // MARK: 시작

    /// 초안 값으로 칸을 채우고 기본 서명을 넣는다. 전달이면 원본 첨부를 가져온다.
    func setUp(app: AppModel, fixDefault: Bool) async {
        guard !didSetUp else { return }
        // 보낼 계정: 초안이 정한 계정, 다시 연 초안은 그 초안의 계정, 아니면 지금 계정
        accountID = draft.fromAccountID ?? draft.draftMessageID.flatMap { app.router.accountID(forMessage: $0) }
            ?? app.accounts.active?.id
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        // 설정 > 작성 > 자동으로 나를 참조·숨은 참조에 포함 (다시 연 초안은 그대로)
        if draft.draftMessageID == nil, let me = account(app)?.email, !me.isEmpty {
            let mode = Prefs.string(Prefs.autoIncludeMe, "none")
            func adding(_ field: String) -> String {
                field.lowercased().contains(me.lowercased()) ? field : (field.isEmpty ? me : field + ", " + me)
            }
            if mode == "cc" { cc = adding(cc) }
            if mode == "bcc" { bcc = adding(bcc) }
        }
        if let pending = PendingDrafts.load(draft.id) {
            replyTo = pending.replyTo ?? ""
            importance = pending.importance ?? "normal"
        }
        showBcc = !bcc.isEmpty
        subject = draft.subject
        fixEnabled = fixDefault
        if let body = draft.bodyHTML {
            // 다시 연 초안: 본문을 그대로 쓰고 서명은 새로 넣지 않는다. 남아 있는 서명 블록이 있으면 메뉴에 보인다.
            editor.setHTML(body)
            signatureID = Self.signatureID(in: body, app: app)
        } else {
            let sig = app.signatures.defaultSignature(kind: draft.kind, account: account(app)?.email)
            signatureID = sig?.id
            // mailto: 링크의 body는 서명 앞 첫머리에
            editor.setHTML((draft.bodyTextHTML ?? "<div><br></div>") + SignatureComposer.block(for: sig) + draft.quoteHTML)
        }
        // .eml 메일을 전달하거나 새 메시지로 편집할 때 그 첨부 (1.0.1)
        if !draft.attachFiles.isEmpty { addFiles(draft.attachFiles) }
        editor.onFileDrop = { [weak self] urls in self?.addFiles(urls) }
        editor.spellcheck = Prefs.bool(Prefs.spellcheck, true)
        editor.onUserEdit = { [weak self] _ in self?.bodyRevision += 1 }
        appliedSignatureID = signatureID
        didSetUp = true
        savedFingerprint = fingerprint
        localFingerprint = fingerprint
        app.openComposeIDs.insert(draft.id)
        if let source = draft.forwardAttachmentsFrom {
            do {
                // 큰 파일은 목록에 내용이 빠져 오므로 하나씩 받아 채운다 (빠뜨리고 전달하지 않게).
                let listed = try await app.service.attachments(messageID: source)
                    .filter { $0.isListed && ($0.odataType ?? "").hasSuffix("fileAttachment") }
                var filled: [FileAttachment] = []
                for a in listed {
                    if let full = await app.loadedAttachment(a, messageID: source) { filled.append(full) }
                }
                forwarded = filled
                savedFingerprint = fingerprint
            } catch {
                errorTitle = L("첨부를 가져오지 못했습니다")
                self.error = L("원본 첨부를 가져오지 못했습니다: \(error.localizedDescription)")
            }
        }
        // 첨부 파일로 전달 (M17): 원본 MIME을 .eml 파일로 붙인다.
        if let source = draft.attachMessageFrom {
            do {
                let data = try await app.service.mimeContent(id: source)
                let base = (draft.attachMessageName ?? L("메시지")).replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let dir = FileManager.default.temporaryDirectory
                    .appending(path: "FAKUKUMail-eml-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appending(path: FilenameEncoder.normalize(String(base.prefix(80))) + ".eml")
                try data.write(to: url)
                files.append(url)
                savedFingerprint = fingerprint
            } catch {
                errorTitle = L("원본을 붙이지 못했습니다")
                self.error = L("전달할 메일의 원본을 가져오지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    // MARK: 첨부와 서명

    /// 파일 선택 창과 끌어다 놓기가 같이 쓴다. 같은 파일은 한 번만, 폴더는 건너뛴다.
    func addFiles(_ urls: [URL]) {
        let result = AttachmentList.merge(files, adding: urls)
        files = result.files
        if !result.skipped.isEmpty {
            errorTitle = L("첨부할 수 없습니다")
            error = L("폴더는 첨부할 수 없습니다: \(result.skipped.joined(separator: ", ")). 압축한 뒤 첨부하세요.")
        }
    }

    func removeFile(_ url: URL) { files.removeAll { $0 == url } }
    func removeForwarded(_ a: FileAttachment) { forwarded.removeAll { $0.id == a.id } }

    /// 서명 메뉴를 바꾸면 본문의 서명 블록을 바꾼다.
    /// 보낼 계정 (고른 것이 없거나 사라졌으면 지금 계정)
    func account(_ app: AppModel) -> MailAccount? {
        app.accounts.accounts.first { $0.id == accountID } ?? app.accounts.active
    }

    /// 보내기·초안을 맡을 메일 서비스: 보낼 계정의 것
    func service(_ app: AppModel) -> any MailService {
        account(app)?.service ?? app.service
    }

    /// 보낸 사람 메뉴에서 계정을 바꿨을 때: 그 계정의 기본 서명으로, 이미 저장한 초안은 원래 계정에서 지운다
    /// (다음 저장 때 새 계정의 임시 보관함에 저장된다).
    func accountChanged(app: AppModel, from old: String?) async {
        guard didSetUp, old != accountID else { return }
        if let id = savedDraftID, let previous = app.accounts.accounts.first(where: { $0.id == old }) {
            try? await previous.service.deleteMessage(id: id)
            savedDraftID = nil
            savedFingerprint = ""
        }
        if draft.bodyHTML == nil {
            let sig = app.signatures.defaultSignature(kind: draft.kind, account: account(app)?.email)
            signatureID = sig?.id
            signatureChanged(app: app)
        }
    }

    func signatureChanged(app: AppModel) {
        guard didSetUp, signatureID != appliedSignatureID else { return }
        appliedSignatureID = signatureID
        editor.replaceSignature(blockHTML: SignatureComposer.block(for: app.signatures.signature(id: signatureID)))
    }

    /// 보정을 켜면 일반 첨부로 나갈 본문 그림 수 (안내 문구용).
    func movedImageCount(imagesAsAttachments: Bool) -> Int {
        fixEnabled && imagesAsAttachments ? HTMLProcessor.bodyImageCount(in: editor.html) : 0
    }

    var windowTitle: String { subject.isEmpty ? draft.kind.label : subject }

    // MARK: 보내기

    func input(app: AppModel) -> ComposeSender.Input {
        ComposeSender.Input(
            from: MailAddress(name: account(app)?.auth.displayName, address: account(app)?.email ?? app.auth.email ?? ""),
            to: to, cc: cc, bcc: bcc, subject: subject, bodyHTML: editor.html,
            files: files,
            extraAttachments: forwarded.compactMap { a in
                a.data.map { OutgoingAttachment(filename: a.name, mimeType: a.contentType ?? "application/octet-stream", data: $0) }
            },
            draft: draft, fixEnabled: fixEnabled, importance: importance, replyTo: replyTo)
    }

    /// 보내고 성공하면 true. 실패하거나 보내기를 취소하면 false (실패면 `error`에 이유).
    /// `undoDelay`초 동안은 "보내기 취소"를 기다린다 (S-036). 주소와 첨부는 기다리기 전에 확인한다.
    func send(app: AppModel, undoDelay: Int = 0) async -> Bool {
        errorTitle = L("보낼 수 없습니다")
        sending = true
        defer { sending = false }
        do {
            let plan = try ComposeSender.prepare(input(app: app), options: ComposeSender.defaultOptions(), forDraft: false,
                                                 requestLimit: requestLimit(app))
            if undoDelay > 0 {
                let go = await countdown(undoDelay)
                if !go { return false }
            }
            if plan.uploads.isEmpty {
                try await service(app).sendMIME(plan.mime)
            } else {
                try await sendLarge(plan, app: app)
            }
            await afterSending(app: app)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// 보낸 뒤: 받는 사람을 주소록에 남기고, 임시 보관함의 초안은 지운다 (실패해도 보낸 것은 그대로다).
    private func afterSending(app: AppModel) async {
        finished = true
        PendingDrafts.remove(draft.id)
        savedOnlyOnMac = false
        let sentTo = [to, cc, bcc].flatMap { AddressParser.parse($0).valid }
        app.addressBook.noteSent(sentTo, me: account(app)?.email)
        app.threadCache = [:]   // 방금 보낸 답장이 대화 내역에 들어가게
        // 보낸 편지함을 보고 있으면 바로 새로 고쳐 방금 보낸 메일이 보이게
        if app.selectedFolder?.kind == "sentitems" { Task { await app.refresh() } }
        if let id = savedDraftID {
            try? await service(app).deleteMessage(id: id)
            savedDraftID = nil
            await app.draftsChanged()
        }
    }

    // MARK: 보내기 취소 (S-036)

    /// 보내기까지 남은 초. nil이면 기다리는 중이 아니다.
    private(set) var sendCountdown: Int?
    @ObservationIgnored private var sendCancelled = false

    /// 남은 시간을 1초씩 줄인다. 다 지나면 true, 그 사이 취소하면 false.
    private func countdown(_ seconds: Int) async -> Bool {
        sendCancelled = false
        sendCountdown = seconds
        defer { sendCountdown = nil }
        while let left = sendCountdown, left > 0 {
            try? await Task.sleep(for: .seconds(1))
            if sendCancelled { return false }
            sendCountdown = left - 1
        }
        return !sendCancelled
    }

    func cancelSend() {
        sendCancelled = true
    }

    // MARK: 예약 보내기 (S-037)

    /// 초안을 만들고(큰 첨부는 올리고) 지연 발송 시각을 붙여 보낸다. Exchange가 그 시각에 보낸다.
    func schedule(app: AppModel, at date: Date) async -> Bool {
        errorTitle = L("예약할 수 없습니다")
        guard ScheduledSend.isValid(date) else {
            error = L("1분 뒤 이후의 시각을 고르세요.")
            return false
        }
        sending = true
        defer { sending = false }
        do {
            let plan = try ComposeSender.prepare(input(app: app), options: ComposeSender.defaultOptions(), forDraft: false,
                                                 requestLimit: requestLimit(app))
            let id = try await service(app).saveDraft(plan.mime, preview: preview, replacing: nil)
            do {
                if !plan.uploads.isEmpty { try await upload(plan.uploads, to: id, app: app) }
                try await service(app).scheduleDraft(id: id, at: date)
                try await service(app).sendDraft(id: id)
            } catch {
                try? await service(app).deleteMessage(id: id)
                throw error
            }
            await afterSending(app: app)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: 초안 (S-022)

    /// 내용 요약. 칸, 본문, 첨부가 같으면 같은 값.
    var fingerprint: String {
        [to, cc, bcc, replyTo, subject, importance, "\(bodyRevision)",
         files.map(\.path).joined(separator: "|"), forwarded.map(\.id).joined(separator: "|")]
            .joined(separator: "\u{1F}")
    }

    /// 처음 연 뒤나 마지막 저장 뒤로 바뀐 것이 있는지.
    var hasUnsavedChanges: Bool { didSetUp && !finished && fingerprint != savedFingerprint }

    /// 이 Mac에 저장한 뒤로 바뀐 것이 있는지 (S-072)
    var hasUnsavedLocalChanges: Bool { didSetUp && !finished && fingerprint != localFingerprint }

    /// 쓰는 내용을 이 Mac에 저장한다 (S-072). 인터넷과 상관없이 바로 끝난다. 바뀐 것이 없으면 아무것도 하지 않는다.
    /// 서버에 저장되면 지우고, 남아 있으면 연결될 때 `AppModel.uploadPendingDrafts`가 올린다.
    @discardableResult
    func saveLocally(app: AppModel, force: Bool = false) -> Bool {
        guard didSetUp, !finished, !sending else { return true }
        guard force || hasUnsavedLocalChanges else { return true }
        // 서버에 저장한 그대로로 돌아왔으면 이 Mac 사본은 필요 없다
        if !force, fingerprint == savedFingerprint, !savedOnlyOnMac {
            PendingDrafts.remove(draft.id)
            localFingerprint = fingerprint
            return true
        }
        let snapshot = fingerprint
        guard let plan = try? ComposeSender.prepare(input(app: app), options: .off, forDraft: true,
                                                    requestLimit: requestLimit(app)) else { return false }
        let p = preview
        let saved = PendingDrafts.save(PendingDraft(
            id: draft.id, accountID: account(app)?.id, replacing: savedDraftID, subject: p.subject, to: p.to, cc: p.cc,
            bodyHTML: p.bodyHTML, mime: plan.mime,
            uploads: plan.uploads.map { .init(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
            savedAt: Date(), toText: to, ccText: cc, bccText: bcc, replyTo: replyTo, importance: importance,
            inReplyTo: draft.inReplyTo, references: draft.references, files: files.map(\.path),
            forwarded: forwarded.compactMap { a in
                a.data.map { .init(filename: a.name, mimeType: a.contentType ?? "application/octet-stream", data: $0) }
            }))
        if saved { localFingerprint = snapshot }
        return saved
    }

    /// 임시 보관함에 저장한다. 바뀐 것이 없으면 그냥 true. 실패하면 false와 `error`.
    /// 먼저 이 Mac에 저장하므로, 오프라인이면 오류 없이 이 Mac에 남겨 두고 true (S-072).
    @discardableResult
    func saveDraft(app: AppModel, force: Bool = false) async -> Bool {
        guard didSetUp, !finished, !savingDraft, !sending else { return true }
        guard force || hasUnsavedChanges || savedOnlyOnMac else { return true }
        let snapshot = fingerprint
        saveLocally(app: app, force: true)
        savingDraft = true
        defer { savingDraft = false }
        let draftInput = input(app: app)
        do {
            let plan = try ComposeSender.prepare(draftInput, options: .off, forDraft: true, requestLimit: requestLimit(app))
            let newID = try await service(app).saveDraft(plan.mime, preview: preview, replacing: savedDraftID)
            savedDraftID = newID
            if !plan.uploads.isEmpty { try await upload(plan.uploads, to: newID, app: app) }
            savedFingerprint = snapshot
            lastDraftSave = Date()
            savedOnlyOnMac = false
            // 저장하는 사이 더 쓴 것이 없으면 이 Mac 사본은 지운다 (더 썼으면 다음 저장 때까지 남긴다)
            if fingerprint == snapshot { PendingDrafts.remove(draft.id) }
            await app.draftsChanged()
            return true
        } catch where OfflineError.isOffline(error) {
            // 인터넷이 없다: 이 Mac에 저장한 것으로 됐다. 연결되면 다음 저장 때(또는 창을 닫은 뒤 앱이) 올린다.
            savedOnlyOnMac = true
            lastDraftSave = Date()
            return true
        } catch {
            errorTitle = L("초안을 저장하지 못했습니다")
            self.error = error.localizedDescription
            return false
        }
    }

    /// 이 메일을 버린다: 저장된 초안이 있으면 지우고, 창을 닫아도 다시 저장하지 않는다.
    func discard(app: AppModel) async {
        finished = true
        PendingDrafts.remove(draft.id)
        savedOnlyOnMac = false
        if let id = savedDraftID {
            try? await service(app).deleteMessage(id: id)
            savedDraftID = nil
            await app.draftsChanged()
        }
    }

    /// 창이 닫힐 때: 쓰던 것이 있으면 초안으로 남긴다. 아무것도 안 쓴 새 창은 남기지 않는다.
    /// 이 Mac에는 먼저 바로 저장하므로 앱이 곧 끝나도 쓰던 것은 남는다 (S-072).
    func windowClosed(app: AppModel) async {
        saveLocally(app: app)
        if hasUnsavedChanges || savedOnlyOnMac { await saveDraft(app: app) }
        app.openComposeIDs.remove(draft.id)
        // 오프라인이라 이 Mac에만 남았으면 임시 보관함 목록에 바로 보이게
        if savedOnlyOnMac { await app.draftsChanged() }
    }

    /// 다시 연 초안에 남아 있는 서명 블록의 서명.
    static func signatureID(in html: String, app: AppModel) -> UUID? {
        guard let range = HTMLProcessor.signatureRanges(in: html).first,
              let match = html[range].range(of: #"data-signature="([0-9A-Fa-f-]{36})""#, options: .regularExpression)
        else { return nil }
        let value = html[match].dropFirst("data-signature=\"".count).dropLast()
        return UUID(uuidString: String(value)).flatMap { app.signatures.signature(id: $0)?.id }
    }

    // MARK: 큰 메일 (S-023)

    private var preview: DraftPreview {
        DraftPreview(subject: subject, to: AddressParser.parse(to).valid, cc: AddressParser.parse(cc).valid,
                     bodyHTML: editor.html)
    }

    /// 4MB를 넘는 메일: 작은 부분으로 초안을 만들고, 큰 첨부를 올린 뒤, 그 초안을 보낸다.
    /// 중간에 실패하면 만든 초안을 지워 임시 보관함에 반쪽짜리가 남지 않게 한다.
    private func sendLarge(_ plan: GraphMailPlan, app: AppModel) async throws {
        let id = try await service(app).saveDraft(plan.mime, preview: preview, replacing: nil)
        do {
            try await upload(plan.uploads, to: id, app: app)
            uploadStatus = L("보내는 중")
            try await service(app).sendDraft(id: id)
            uploadStatus = nil
        } catch {
            try? await service(app).deleteMessage(id: id)
            throw error
        }
    }

    private func upload(_ list: [OutgoingAttachment], to id: String, app: AppModel) async throws {
        defer {
            uploadStatus = nil
            uploadFraction = nil
        }
        for (index, attachment) in list.enumerated() {
            uploadStatus = L("큰 첨부 올리는 중 \(index + 1)/\(list.count)")
            uploadFraction = Double(index) / Double(list.count)
            try await service(app).uploadAttachment(attachment, toMessage: id) { [weak self] part in
                self?.uploadFraction = (Double(index) + part) / Double(list.count)
            }
        }
    }

    /// iCloud·Gmail은 MIME 하나로 보낸다 (Graph의 4MB 한도와 나눠 올리기가 없다, M24)
    private func requestLimit(_ app: AppModel) -> Int {
        account(app)?.imap != nil ? .max : MIMEBuilder.graphRequestLimit
    }

    /// 첨부 막대 안내: 큰 첨부는 따로 올려 보낸다 (대략 2MB부터).
    var hasLargeAttachments: Bool {
        let fileSizes = files.compactMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil }
        return (fileSizes + forwarded.compactMap(\.size)).contains { $0 >= 2 * 1024 * 1024 }
    }
}
