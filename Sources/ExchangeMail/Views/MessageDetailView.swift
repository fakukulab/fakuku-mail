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

struct MessageHeader: View {
    let message: MailMessage
    /// 목록에 보일 첨부 (인라인 그림 빼고)
    let attachments: [FileAttachment]
    let preview: (FileAttachment) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                if let vip = model.mailboxes.vip(for: message) {
                    VIPBadge(vip: vip)
                }
                Text(message.from?.emailAddress.display ?? "(보낸 사람 없음)")
                    .font(.headline)
                    .textSelection(.enabled)
                    // 보낸 사람을 VIP로 (S-045)
                    .contextMenu {
                        if model.mailboxes.vip(for: message) == nil {
                            Button("VIP로 지정…") { model.editVIP(for: message) }
                        } else {
                            Button("VIP 이름·아이콘 변경…") { model.editVIP(for: message) }
                            Button("VIP에서 빼기") {
                                if let address = message.from?.emailAddress.address { model.removeVIP(address: address) }
                            }
                        }
                    }
                if let address = message.from?.emailAddress.address, message.from?.emailAddress.name?.isEmpty == false {
                    Text("<\(address)>")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                let isVIP = model.mailboxes.vip(for: message) != nil
                Button(isVIP ? "VIP 변경" : "VIP로 지정", systemImage: isVIP ? "star.fill" : "star") {
                    model.editVIP(for: message)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(isVIP ? "VIP 이름·아이콘 변경 (오른쪽 클릭으로 VIP에서 빼기)" : "보낸 사람을 VIP로 지정 (⌃⌘V)")
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
