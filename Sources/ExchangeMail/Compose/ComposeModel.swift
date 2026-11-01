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
    private(set) var didSetUp = false
    var error: String?
    var errorTitle = "보낼 수 없습니다"

    init(draft: ComposeDraft) {
        self.draft = draft
    }

    // MARK: 시작

    /// 초안 값으로 칸을 채우고 기본 서명을 넣는다. 전달이면 원본 첨부를 가져온다.
    func setUp(app: AppModel, fixDefault: Bool) async {
        guard !didSetUp else { return }
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        showBcc = !draft.bcc.isEmpty
        subject = draft.subject
        fixEnabled = fixDefault
        let sig = app.signatures.defaultSignature(kind: draft.kind, account: app.auth.email)
        signatureID = sig?.id
        editor.setHTML("<div><br></div>" + SignatureComposer.block(for: sig) + draft.quoteHTML)
        editor.onFileDrop = { [weak self] urls in self?.addFiles(urls) }
        didSetUp = true
        if let source = draft.forwardAttachmentsFrom {
            do {
                forwarded = try await app.service.attachments(messageID: source).filter { $0.isListed && $0.isFile }
            } catch {
                errorTitle = "첨부를 가져오지 못했습니다"
                self.error = "원본 첨부를 가져오지 못했습니다: \(error.localizedDescription)"
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
        guard didSetUp else { return }
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

    /// 보내고 성공하면 true. 실패하면 `error`에 이유를 둔다.
    func send(app: AppModel) async -> Bool {
        errorTitle = "보낼 수 없습니다"
        sending = true
        defer { sending = false }
        do {
            let mime = try ComposeSender.build(input(app: app), options: ComposeSender.defaultOptions())
            try await app.service.sendMIME(mime)
            let sentTo = [to, cc, showBcc ? bcc : ""].flatMap { AddressParser.parse($0).valid }
            app.addressBook.noteSent(sentTo, me: app.auth.email)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
