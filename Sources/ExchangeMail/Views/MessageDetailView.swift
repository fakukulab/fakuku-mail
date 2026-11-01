import ExchangeMailKit
import SwiftUI

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let m = model.detail, m.id == model.selectedMessageID {
                VStack(alignment: .leading, spacing: 0) {
                    MessageHeader(message: m)
                    if model.detailHasRemoteContent && !model.remoteContentAllowed {
                        remoteBar
                    }
                    Divider()
                    HTMLView(html: MailContent.page(body: model.detailBody, allowRemote: model.remoteContentAllowed)) { url in
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
            Button("보관", systemImage: "archivebox") { Task { await model.archiveSelected() } }
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
