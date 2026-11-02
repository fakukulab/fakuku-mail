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
    var subject = ""
    var files: [URL] = []
    var forwarded: [FileAttachment] = []
    var signatureID: UUID?
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
    /// 보냈거나 버렸으면 창을 닫아도 저장하지 않는다.
    private(set) var finished = false
    /// 사람이 본문을 고친 횟수. 웹 편집기는 넣은 HTML을 정리해서 돌려주므로 HTML 문자열로 비교하지 않는다.
    private(set) var bodyRevision = 0
    /// 본문에 지금 들어 있는 서명. 메뉴 값이 이것과 다를 때만 본문을 바꾼다.
    @ObservationIgnored private var appliedSignatureID: UUID?
    var error: String?
    var errorTitle = "보낼 수 없습니다"

    init(draft: ComposeDraft) {
        self.draft = draft
        savedDraftID = draft.draftMessageID
    }

    // MARK: 시작

    /// 초안 값으로 칸을 채우고 기본 서명을 넣는다. 전달이면 원본 첨부를 가져온다.
    func setUp(app: AppModel, fixDefault: Bool) async {
        guard !didSetUp else { return }
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        // 설정 > 작성 > 자동으로 나를 참조·숨은 참조에 포함 (다시 연 초안은 그대로)
        if draft.draftMessageID == nil, let me = app.auth.email, !me.isEmpty {
            let mode = Prefs.string(Prefs.autoIncludeMe, "none")
            func adding(_ field: String) -> String {
                field.lowercased().contains(me.lowercased()) ? field : (field.isEmpty ? me : field + ", " + me)
            }
            if mode == "cc" { cc = adding(cc) }
            if mode == "bcc" { bcc = adding(bcc) }
        }
        showBcc = !bcc.isEmpty
        subject = draft.subject
        fixEnabled = fixDefault
        if let body = draft.bodyHTML {
            // 다시 연 초안: 본문을 그대로 쓰고 서명은 새로 넣지 않는다. 남아 있는 서명 블록이 있으면 메뉴에 보인다.
            editor.setHTML(body)
            signatureID = Self.signatureID(in: body, app: app)
        } else {
            let sig = app.signatures.defaultSignature(kind: draft.kind, account: app.auth.email)
            signatureID = sig?.id
            editor.setHTML("<div><br></div>" + SignatureComposer.block(for: sig) + draft.quoteHTML)
        }
        editor.onFileDrop = { [weak self] urls in self?.addFiles(urls) }
        editor.spellcheck = Prefs.bool(Prefs.spellcheck, true)
        editor.onUserEdit = { [weak self] _ in self?.bodyRevision += 1 }
        appliedSignatureID = signatureID
        didSetUp = true
        savedFingerprint = fingerprint
        if let source = draft.forwardAttachmentsFrom {
            do {
                forwarded = try await app.service.attachments(messageID: source).filter { $0.isListed && $0.isFile }
                savedFingerprint = fingerprint
            } catch {
                errorTitle = "첨부를 가져오지 못했습니다"
                self.error = "원본 첨부를 가져오지 못했습니다: \(error.localizedDescription)"
            }
        }
        // 첨부 파일로 전달 (M17): 원본 MIME을 .eml 파일로 붙인다.
        if let source = draft.attachMessageFrom {
            do {
                let data = try await app.service.mimeContent(id: source)
                let base = (draft.attachMessageName ?? "메시지").replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let dir = FileManager.default.temporaryDirectory
                    .appending(path: "ExchangeMail-eml-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appending(path: FilenameEncoder.normalize(String(base.prefix(80))) + ".eml")
                try data.write(to: url)
                files.append(url)
                savedFingerprint = fingerprint
            } catch {
                errorTitle = "원본을 붙이지 못했습니다"
                self.error = "전달할 메일의 원본을 가져오지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    // MARK: 첨부와 서명

    /// 파일 선택 창과 끌어다 놓기가 같이 쓴다. 같은 파일은 한 번만, 폴더는 건너뛴다.
    func addFiles(_ urls: [URL]) {
        let result = AttachmentList.merge(files, adding: urls)
        files = result.files
        if !result.skipped.isEmpty {
            errorTitle = "첨부할 수 없습니다"
            error = "폴더는 첨부할 수 없습니다: \(result.skipped.joined(separator: ", ")). 압축한 뒤 첨부하세요."
        }
    }

    func removeFile(_ url: URL) { files.removeAll { $0 == url } }
    func removeForwarded(_ a: FileAttachment) { forwarded.removeAll { $0.id == a.id } }

    /// 서명 메뉴를 바꾸면 본문의 서명 블록을 바꾼다.
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
            from: MailAddress(name: app.auth.displayName, address: app.auth.email ?? ""),
            to: to, cc: cc, bcc: showBcc ? bcc : "", subject: subject, bodyHTML: editor.html,
            files: files,
            extraAttachments: forwarded.compactMap { a in
                a.data.map { OutgoingAttachment(filename: a.name, mimeType: a.contentType ?? "application/octet-stream", data: $0) }
            },
            draft: draft, fixEnabled: fixEnabled)
    }

    /// 보내고 성공하면 true. 실패하거나 보내기를 취소하면 false (실패면 `error`에 이유).
    /// `undoDelay`초 동안은 "보내기 취소"를 기다린다 (S-036). 주소와 첨부는 기다리기 전에 확인한다.
    func send(app: AppModel, undoDelay: Int = 0) async -> Bool {
        errorTitle = "보낼 수 없습니다"
        sending = true
        defer { sending = false }
        do {
            let plan = try ComposeSender.prepare(input(app: app), options: ComposeSender.defaultOptions(), forDraft: false)
            if undoDelay > 0 {
                let go = await countdown(undoDelay)
                if !go { return false }
            }
            if plan.uploads.isEmpty {
                try await app.service.sendMIME(plan.mime)
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
        let sentTo = [to, cc, showBcc ? bcc : ""].flatMap { AddressParser.parse($0).valid }
        app.addressBook.noteSent(sentTo, me: app.auth.email)
        if let id = savedDraftID {
            try? await app.service.deleteMessage(id: id)
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
        errorTitle = "예약할 수 없습니다"
        guard ScheduledSend.isValid(date) else {
            error = "1분 뒤 이후의 시각을 고르세요."
            return false
        }
        sending = true
        defer { sending = false }
        do {
            let plan = try ComposeSender.prepare(input(app: app), options: ComposeSender.defaultOptions(), forDraft: false)
            let id = try await app.service.saveDraft(plan.mime, preview: preview, replacing: nil)
            do {
                if !plan.uploads.isEmpty { try await upload(plan.uploads, to: id, app: app) }
                try await app.service.scheduleDraft(id: id, at: date)
                try await app.service.sendDraft(id: id)
            } catch {
                try? await app.service.deleteMessage(id: id)
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
        [to, cc, showBcc ? bcc : "", subject, "\(bodyRevision)",
         files.map(\.path).joined(separator: "|"), forwarded.map(\.id).joined(separator: "|")]
            .joined(separator: "\u{1F}")
    }

    /// 처음 연 뒤나 마지막 저장 뒤로 바뀐 것이 있는지.
    var hasUnsavedChanges: Bool { didSetUp && !finished && fingerprint != savedFingerprint }

    /// 임시 보관함에 저장한다. 바뀐 것이 없으면 그냥 true. 실패하면 false와 `error`.
    @discardableResult
    func saveDraft(app: AppModel, force: Bool = false) async -> Bool {
        guard didSetUp, !finished, !savingDraft, !sending else { return true }
        guard force || hasUnsavedChanges else { return true }
        let snapshot = fingerprint
        savingDraft = true
        defer { savingDraft = false }
        let draftInput = input(app: app)
        do {
            let plan = try ComposeSender.prepare(draftInput, options: .off, forDraft: true)
            let newID = try await app.service.saveDraft(plan.mime, preview: preview, replacing: savedDraftID)
            savedDraftID = newID
            if !plan.uploads.isEmpty { try await upload(plan.uploads, to: newID, app: app) }
            savedFingerprint = snapshot
            lastDraftSave = Date()
            await app.draftsChanged()
            return true
        } catch {
            errorTitle = "초안을 저장하지 못했습니다"
            self.error = error.localizedDescription
            return false
        }
    }

    /// 이 메일을 버린다: 저장된 초안이 있으면 지우고, 창을 닫아도 다시 저장하지 않는다.
    func discard(app: AppModel) async {
        finished = true
        if let id = savedDraftID {
            try? await app.service.deleteMessage(id: id)
            savedDraftID = nil
            await app.draftsChanged()
        }
    }

    /// 창이 닫힐 때: 쓰던 것이 있으면 초안으로 남긴다. 아무것도 안 쓴 새 창은 남기지 않는다.
    func windowClosed(app: AppModel) async {
        guard hasUnsavedChanges else { return }
        await saveDraft(app: app)
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
        let id = try await app.service.saveDraft(plan.mime, preview: preview, replacing: nil)
        do {
            try await upload(plan.uploads, to: id, app: app)
            uploadStatus = "보내는 중"
            try await app.service.sendDraft(id: id)
            uploadStatus = nil
        } catch {
            try? await app.service.deleteMessage(id: id)
            throw error
        }
    }

    private func upload(_ list: [OutgoingAttachment], to id: String, app: AppModel) async throws {
        defer {
            uploadStatus = nil
            uploadFraction = nil
        }
        for (index, attachment) in list.enumerated() {
            uploadStatus = "큰 첨부 올리는 중 \(index + 1)/\(list.count)"
            uploadFraction = Double(index) / Double(list.count)
            try await app.service.uploadAttachment(attachment, toMessage: id) { [weak self] part in
                self?.uploadFraction = (Double(index) + part) / Double(list.count)
            }
        }
    }

    /// 첨부 막대 안내: 큰 첨부는 따로 올려 보낸다 (대략 2MB부터).
    var hasLargeAttachments: Bool {
        let fileSizes = files.compactMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil }
        return (fileSizes + forwarded.compactMap(\.size)).contains { $0 >= 2 * 1024 * 1024 }
    }
}
