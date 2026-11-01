import ExchangeMailKit
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMessageID) {
            ForEach(model.messages) { m in
                MessageRow(message: m)
                    .tag(m.id)
                    .contextMenu { contextMenu(for: m) }
                    .onAppear {
                        if m.id == model.messages.last?.id { Task { await model.loadMore() } }
                    }
            }
            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            }
        }
        .onDeleteCommand { Task { await model.deleteSelected(undoManager: undoManager) } }
        // ↑↓는 List가 처리한다. Space/⇧Space는 본문을 넘기고, 끝에서 다음/이전 메일로 (S-019).
        .onKeyPress(.space, phases: .down) { press in
            let down = !press.modifiers.contains(.shift)
            Task { await model.pageOrAdvance(down: down) }
            return .handled
        }
        .overlay { emptyState }
        .navigationTitle(model.selectedFolder?.displayName ?? "메일")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("받은 메일 가져오기", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .help("받은 메일 가져오기 (⇧⌘N)")
                Button("새로운 메시지", systemImage: "square.and.pencil") {
                    openWindow(id: "compose", value: ComposeDraft())
                }
                .help("새로운 메시지 (⌘N)")
            }
        }
    }

    private var subtitle: String {
        guard let f = model.selectedFolder else { return "" }
        let unread = f.unreadItemCount ?? 0
        let total = f.totalItemCount ?? model.messages.count
        return unread > 0 ? "메시지 \(total)개, 읽지 않음 \(unread)개" : "메시지 \(total)개"
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.messages.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.selectedFolderID != nil {
                ContentUnavailableView("메시지 없음", systemImage: model.selectedFolder?.symbol ?? "tray",
                                       description: Text("이 폴더에 메시지가 없습니다."))
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for m: MailMessage) -> some View {
        Button("답장") { compose(.reply, for: m) }
        Button("전체 답장") { compose(.replyAll, for: m) }
        Button("전달") { compose(.forward, for: m) }
        Divider()
        Button(m.isUnread ? "읽음으로 표시" : "읽지 않음으로 표시") {
            Task { await model.setRead(id: m.id, m.isUnread) }
        }
        Divider()
        Button("보관") {
            model.selectedMessageID = m.id
            Task { await model.archiveSelected() }
        }
        Button("지우기", role: .destructive) {
            model.selectedMessageID = m.id
            Task { await model.deleteSelected(undoManager: undoManager) }
        }
    }

    /// 답장은 본문이 필요하다: 고른 메일이 아니면 먼저 고르고 본문을 불러온다.
    private func compose(_ kind: ComposeKind, for m: MailMessage) {
        Task {
            if model.detail?.id != m.id {
                model.selectedMessageID = m.id
                await model.loadDetail()
            }
            if let draft = model.draft(kind) { openWindow(id: "compose", value: draft) }
        }
    }
}

struct MessageRow: View {
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle()
                .fill(message.isUnread ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear))
                .frame(width: 8, height: 8)
                .padding(.top, Space.xs)
                .accessibilityLabel(message.isUnread ? "읽지 않음" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(message.from?.emailAddress.display ?? "(보낸 사람 없음)")
                        .fontWeight(message.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    if message.hasAttachments == true {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("첨부 있음")
                    }
                    Text(message.receivedDateTime.map { MailDate.listLabel($0) } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(message.title)
                    .lineLimit(1)
                Text(message.bodyPreview ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Space.xs)
    }
}
