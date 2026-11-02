import ExchangeMailKit
import QuickLook
import SwiftUI

struct MessageDetailView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @Environment(\.undoManager) var undoManager
    @AppStorage("list.threaded") private var threaded = true

    var body: some View {
        Group {
            if model.multipleSelectionCount > 0 {
                ContentUnavailableView("메시지 \(model.multipleSelectionCount)개 선택됨", systemImage: "tray.full",
                                       description: Text("보관, 지우기, 이동, 읽음, 깃발을 한 번에 할 수 있습니다."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let m = model.detail, m.id == model.displayedMessageID {
                VStack(alignment: .leading, spacing: 0) {
                    if threaded && model.thread.count > 1 {
                        ThreadStrip()
                        Divider()
                    }
                    MessageHeader(message: m, attachments: model.listedAttachments) { model.preview($0) }
                    if model.isDraftSelected {
                        draftBar
                    }
                    if m.isMeetingRequest, let event = m.event {
                        MeetingBar(event: event)
                    }
                    if model.detailHasRemoteContent && !model.remoteContentAllowed {
                        RemoteContentBar { model.allowRemoteContentForSelection() }
                    }
                    Divider()
                    HTMLView(html: MailContent.page(body: model.detailBody, allowRemote: model.remoteContentAllowed),
                             scroller: model.pageScroller, onPrint: { model.printDisplayed() }) { url in
                        openWindow(id: "compose", value: ComposeDraft.mailto(url))
                    }
                }
            } else if model.selectedMessageID != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("메시지를 선택하세요", systemImage: "envelope")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 보기 > 도구 막대 사용자화…로 항목을 넣고 뺀다 (S-044).
        .toolbar(id: "mail") { mailToolbar }
        // 첨부 미리보기 (S-032)
        .quickLookPreview(Binding(get: { model.previewURL }, set: { model.previewURL = $0 }))
    }

    /// 임시 보관함의 초안: 이어서 쓰기 (S-022)
    private var draftBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "pencil.and.list.clipboard")
                .foregroundStyle(.secondary)
            Text("저장된 초안입니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("이어서 쓰기") {
                if let d = model.resumeDraft() { openWindow(id: "compose", value: d) }
            }
            .controlSize(.small)
            .help("작성 창에서 이어서 씁니다 (⌘O)")
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    func compose(_ kind: ComposeKind) {
        if let draft = model.draft(kind) { openWindow(id: "compose", value: draft) }
    }
}

/// 원격 이미지를 막았다는 안내와 불러오기 (본문 열과 메시지 창)
struct RemoteContentBar: View {
    let allow: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text("원격 이미지를 차단했습니다. 보낸 사람이 메일을 열었는지 알 수 없게 합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("불러오기", action: allow)
                .controlSize(.small)
                .help("이 메일의 원격 이미지를 불러옵니다 (⇧⌘I)")
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}

/// 메인 창 본문 열 위의 도구 막대 (S-044). 보기 > 도구 막대 사용자화…로 넣고 뺀다.
/// 목록 열의 필터·정렬·새로 고침·새로운 메시지는 그 열에 붙어 있어 사용자화하지 않는다.
extension MessageDetailView {
    @ToolbarContentBuilder
    var mailToolbar: some CustomizableToolbarContent {
        ToolbarSpacer(.flexible)
        organize
        ToolbarSpacer(.fixed)
        reply
        extras
    }

    private var noSelection: Bool { model.selectedIDs.isEmpty }

    @ToolbarContentBuilder
    private var organize: some CustomizableToolbarContent {
        ToolbarItem(id: "archive") {
            Button("보관", systemImage: "archivebox") { Task { await model.archiveSelected(undoManager: undoManager) } }
                .help("보관 (⌃⌘A)")
                .disabled(noSelection)
        }
        ToolbarItem(id: "delete") {
            Button("지우기", systemImage: "trash") { Task { await model.deleteSelected(undoManager: undoManager) } }
                .help("지우기 (Delete)")
                .disabled(noSelection)
        }
        ToolbarItem(id: "junk") {
            Button("정크", systemImage: "xmark.bin") { Task { await model.toggleJunkSelected(undoManager: undoManager) } }
                .help("정크 메일로 표시 / 정크 아님 (⇧⌘J)")
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "move") {
            Button("이동", systemImage: "folder") { model.showMovePicker = true }
                .help("다른 폴더로 이동 (⇧⌘M)")
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "flag") {
            Button("깃발", systemImage: "flag") { Task { await model.toggleFlagSelected() } }
                .help("깃발 달기/떼기 (⇧⌘L)")
                .disabled(noSelection)
        }
    }

    @ToolbarContentBuilder
    private var reply: some CustomizableToolbarContent {
        ToolbarItem(id: "reply") {
            Button("답장", systemImage: "arrowshape.turn.up.left") { compose(.reply) }
                .help("답장 (⌘R)")
                .disabled(model.detail == nil)
        }
        ToolbarItem(id: "replyAll") {
            Button("전체 답장", systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll) }
                .help("전체 답장 (⇧⌘R)")
                .disabled(model.detail == nil)
        }
        ToolbarItem(id: "forward") {
            Button("전달", systemImage: "arrowshape.turn.up.right") { compose(.forward) }
                .help("전달 (⇧⌘F)")
                .disabled(model.detail == nil)
        }
    }

    /// 처음에는 숨겨 두고 사용자화 시트에서 끌어 넣는 항목
    @ToolbarContentBuilder
    private var extras: some CustomizableToolbarContent {
        ToolbarItem(id: "read") {
            Button("읽음/읽지 않음", systemImage: "envelope.badge") { Task { await model.toggleReadSelected() } }
                .help("읽음 또는 읽지 않음으로 표시 (⇧⌘U)")
                .disabled(noSelection)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "print") {
            Button("인쇄", systemImage: "printer") { model.printDisplayed() }
                .help("인쇄 (⌘P)")
                .disabled(model.detail == nil || model.multipleSelectionCount > 0)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "openWindow") {
            Button("새 창에서 열기", systemImage: "macwindow.on.rectangle") { openInWindow() }
                .help("새 창에서 열기 (⌘O)")
                .disabled(model.detail == nil || model.multipleSelectionCount > 0)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "newMessage") {
            Button("새로운 메시지", systemImage: "square.and.pencil") { openWindow(id: "compose", value: ComposeDraft()) }
                .help("새로운 메시지 (⌘N)")
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "getMail") {
            Button("받은 메일 가져오기", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("받은 메일 가져오기 (⇧⌘N)")
        }
        .defaultCustomization(.hidden)
    }

    private func openInWindow() {
        switch model.openTarget() {
        case .compose(let draft): openWindow(id: "compose", value: draft)
        case .message(let id): openWindow(id: "message", value: id)
        case nil: break
        }
    }
}

struct MessageHeader: View {
    let message: MailMessage
    /// 목록에 보일 첨부 (인라인 그림 빼고)
    let attachments: [FileAttachment]
    let preview: (FileAttachment) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.from?.emailAddress.display ?? "(보낸 사람 없음)")
                    .font(.headline)
                    .textSelection(.enabled)
                if let address = message.from?.emailAddress.address, message.from?.emailAddress.name?.isEmpty == false {
                    Text("<\(address)>")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(message.receivedDateTime.map { MailDate.long($0) } ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(message.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            recipients("받는 사람:", message.toRecipients)
            recipients("참조:", message.ccRecipients)
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(attachments) { a in
                            // 누르면 훑어보기, 오른쪽 클릭으로 저장 (S-032)
                            Button {
                                preview(a)
                            } label: {
                                Label("\(FilenameEncoder.normalize(a.name))  \(a.sizeLabel)", systemImage: "paperclip")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .help("훑어보기 (⌘Y). 오른쪽 클릭으로 저장")
                            .contextMenu {
                                Button("훑어보기") { preview(a) }
                                Button("저장…") { model.save(attachment: a) }
                            }
                            // Finder나 데스크톱으로 끌어 저장 (S-035)
                            .onDrag { model.dragProvider(for: a) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.lg)
    }

    @ViewBuilder
    private func recipients(_ label: String, _ list: [Recipient]?) -> some View {
        if let list, !list.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(list.map(\.emailAddress.display).joined(separator: ", "))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}

/// 대화 보기 (S-025): 대화의 메일을 오래된 순으로 한 줄씩. 누르면 아래에 그 메일이 펼쳐진다.
struct ThreadStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("대화 \(model.thread.count)통")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xs)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.thread) { m in
                        ThreadRow(message: m, isShown: m.id == model.displayedMessageID,
                                  folderTag: model.folderTag(for: m), me: model.auth.email) {
                            model.showInThread(m.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 176)
        }
    }
}

struct ThreadRow: View {
    let message: MailMessage
    let isShown: Bool
    let folderTag: String?
    let me: String?
    let open: () -> Void

    private var sender: String {
        let address = message.from?.emailAddress.address?.lowercased()
        return address != nil && address == me?.lowercased() ? "나" : (message.from?.emailAddress.display ?? "")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                // 펼친 메일은 강조색 막대
                RoundedRectangle(cornerRadius: 1)
                    .fill(isShown ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear))
                    .frame(width: 2, height: 16)
                Text(sender)
                    .fontWeight(message.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                Text(message.bodyPreview ?? message.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                if let folderTag {
                    Text(folderTag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs)
                        .background(.quaternary, in: Capsule())
                }
                Text(message.receivedDateTime.map { MailDate.listLabel($0) } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
            .background(isShown ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear))
        }
        .buttonStyle(.plain)
        .help(isShown ? "지금 보고 있는 메일" : "이 메일 펼치기")
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }
}

/// 회의 초대 (S-038): 일시·장소와 수락 / 미정 / 거절
struct MeetingBar: View {
    let event: MailEvent
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.whenText())
                    .font(.callout.weight(.semibold))
                if let place = event.location?.displayName, !place.isEmpty {
                    Text(place)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // 서버가 기록한 내 응답 (보낸 뒤 다시 읽어 온 값)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Label(MeetingResponse.describe(event.responseStatus?.response),
                      systemImage: event.response == nil ? "questionmark.circle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ControlGroup {
                ForEach(MeetingResponse.allCases, id: \.self) { r in
                    Button(r.label) {
                        Task {
                            busy = true
                            await model.respondToMeeting(r)
                            busy = false
                        }
                    }
                    .disabled(busy || event.response == r)
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}
