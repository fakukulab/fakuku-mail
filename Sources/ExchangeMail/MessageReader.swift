import AppKit
import ExchangeMailKit
import Observation
import SwiftUI

/// 별도 창 하나가 읽는 메일 한 통 (S-043). 목록 선택과 따로 움직인다.
/// 서버 호출과 목록 갱신은 AppModel이 하고, 이 모델은 창에 보일 것만 들고 있다.
@Observable
final class MessageReader {
    let messageID: String
    private(set) var message: MailMessage?
    /// cid 그림을 data: URI로 바꾼 본문
    private(set) var body: MailMessage.Body?
    private(set) var attachments: [FileAttachment] = []
    private(set) var allowRemote = false
    /// 열지 못했을 때 창에 보일 이유
    private(set) var failure: String?
    /// 보관·지우기 뒤 창을 닫는다.
    private(set) var closed = false
    /// Quick Look으로 보는 첨부
    var previewURL: URL?
    @ObservationIgnored let pageScroller = PageScroller()

    init(messageID: String) {
        self.messageID = messageID
    }

    var listedAttachments: [FileAttachment] { attachments.filter(\.isListed) }
    var hasRemoteContent: Bool { body.map { $0.isHTML && MailContent.hasRemoteContent($0.content) } ?? false }

    func load(using model: AppModel) async {
        do {
            let m = try await model.service.message(id: messageID)
            var files: [FileAttachment] = []
            if (m.hasAttachments ?? false) || (m.body?.content.contains("cid:") ?? false) {
                files = try await model.service.attachments(messageID: messageID)
            }
            message = m
            attachments = files
            body = MailContent.displayBody(m.body, attachments: files)
            failure = nil
            if m.isUnread && Prefs.string(Prefs.markRead, "now") != "never" {
                await model.setRead(id: messageID, true)
                message?.isRead = true
            }
        } catch {
            failure = OfflineError.isOffline(error)
                ? "오프라인이고 이 메일은 이 Mac에 저장되어 있지 않습니다. 연결되면 다시 열어 주세요."
                : "메일이 다른 폴더로 옮겨졌거나 지워졌을 수 있습니다. (\(error.localizedDescription))"
        }
    }

    func allowRemoteContent() {
        allowRemote = true
    }

    // MARK: 동작 (창의 도구 막대와 메시지 메뉴가 같이 쓴다)

    func draft(_ kind: ComposeKind, model: AppModel) -> ComposeDraft? {
        guard let message else { return nil }
        return model.draft(kind, message: message, body: body)
    }

    func preview(_ attachment: FileAttachment, model: AppModel) {
        Task {
            guard let full = await model.loadedAttachment(attachment, messageID: messageID) else { return }
            if let i = attachments.firstIndex(where: { $0.id == full.id }) { attachments[i] = full }
            previewURL = model.previewFile(for: full)
        }
    }

    func previewFirstAttachment(model: AppModel) {
        if let first = listedAttachments.first { preview(first, model: model) }
    }

    func print(model: AppModel) {
        guard let message else { return }
        model.printMessage(message, body: body, remote: model.remoteMode(for: message, allowed: allowRemote))
    }

    func setFlagColor(_ color: FlagColor, model: AppModel) async {
        guard let message else { return }
        if await model.setFlagColor(color, for: message) { self.message?.flag = .flagged }
    }

    func toggleFlag(model: AppModel) async {
        guard let message else { return }
        let flag = !message.isFlagged
        if await model.setFlag(id: message.id, flagged: flag) {
            self.message?.flag = flag ? .flagged : .notFlagged
        }
    }

    /// 보관(archive) 또는 지우기(deleteditems). 옮기면 창을 닫는다. ⌘Z는 메인 창에서 되돌린다.
    func move(to destination: String, undoName: String, model: AppModel) async {
        guard let message else { return }
        if await model.moveOpened(message, to: destination, undoName: undoName) {
            closed = true
        }
    }
}

/// 앱 타깃은 기본이 메인 액터라, 키는 nonisolated로 둔다 (Kit 밖의 프로토콜 준수가 메인 액터에 묶이지 않게).
nonisolated struct MessageReaderKey: FocusedValueKey {
    typealias Value = MessageReader
}

extension FocusedValues {
    /// 앞에 있는 메시지 창의 리더. 메시지 메뉴가 이 창의 메일에 동작하게 한다 (S-043).
    nonisolated var messageReader: MessageReader? {
        get { self[MessageReaderKey.self] }
        set { self[MessageReaderKey.self] = newValue }
    }
}
