import ExchangeMailKit
import SwiftUI

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @AppStorage("list.threaded") private var threaded = true

    var body: some View {
        Group {
            if let m = model.detail, m.id == model.displayedMessageID {
                VStack(alignment: .leading, spacing: 0) {
                    if threaded && model.thread.count > 1 {
                        ThreadStrip()
                        Divider()
                    }
                    MessageHeader(message: m)
                    if model.isDraftSelected {
                        draftBar
                    }
                    if model.detailHasRemoteContent && !model.remoteContentAllowed {
                        remoteBar
                    }
                    Divider()
                    HTMLView(html: MailContent.page(body: model.detailBody, allowRemote: model.remoteContentAllowed),
                             scroller: model.pageScroller) { url in
                        // 본문의 mailto: 링크는 새 메시지로
                        let address = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                            .components(separatedBy: "?").first?.removingPercentEncoding ?? ""
                        openWindow(id: "compose", value: ComposeDraft(to: address))
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
        .toolbar { toolbar }
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

    private var remoteBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text("원격 이미지를 차단했습니다. 보낸 사람이 메일을 열었는지 알 수 없게 합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("불러오기") { model.allowRemoteContentForSelection() }
                .controlSize(.small)
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // 선택한 메일에 대한 동작은 본문 열 위에, 오른쪽으로 민다.
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            Button("보관", systemImage: "archivebox") { Task { await model.archiveSelected(undoManager: undoManager) } }
                .help("보관 (⌃⌘A)")
                .disabled(model.detail == nil)
            Button("지우기", systemImage: "trash") { Task { await model.deleteSelected(undoManager: undoManager) } }
                .help("지우기 (Delete)")
                .disabled(model.detail == nil)
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button("답장", systemImage: "arrowshape.turn.up.left") { compose(.reply) }
                .help("답장 (⌘R)")
                .disabled(model.detail == nil)
            Button("전체 답장", systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll) }
                .help("전체 답장 (⇧⌘R)")
                .disabled(model.detail == nil)
            Button("전달", systemImage: "arrowshape.turn.up.right") { compose(.forward) }
                .help("전달 (⇧⌘F)")
                .disabled(model.detail == nil)
        }
    }

    private func compose(_ kind: ComposeKind) {
        if let draft = model.draft(kind) { openWindow(id: "compose", value: draft) }
    }
}

struct MessageHeader: View {
    let message: MailMessage
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
            if !model.listedAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(model.listedAttachments) { a in
                            Button {
                                model.save(attachment: a)
                            } label: {
                                Label("\(FilenameEncoder.normalize(a.name))  \(a.sizeLabel)", systemImage: "paperclip")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .help("저장…")
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
