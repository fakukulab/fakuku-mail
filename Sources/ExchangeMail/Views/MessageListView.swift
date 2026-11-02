import ExchangeMailKit
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    /// 보기 > 대화별로 정리 (S-025)
    @AppStorage("list.threaded") private var threaded = true

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if threaded {
                // 대화 한 줄의 tag는 대화의 최근 메일 id다.
                let conversations = model.conversations
                ForEach(conversations) { c in
                    ConversationRow(conversation: c, me: model.auth.email)
                        .tag(c.latest.id)
                        .draggable(model.dragPayload(for: c.latest.id))
                        .onAppear {
                            if c.id == conversations.last?.id { Task { await model.loadMore() } }
                        }
                }
            } else {
                ForEach(model.messages) { m in
                    MessageRow(message: m, folderTag: model.folderTag(for: m))
                        .tag(m.id)
                        .draggable(model.dragPayload(for: m.id))
                        .onAppear {
                            if m.id == model.messages.last?.id { Task { await model.loadMore() } }
                        }
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
        // 오른쪽 클릭은 고른 줄 전체에, 두 번 클릭은 초안 이어서 쓰기 (S-027).
        .contextMenu(forSelectionType: String.self) { rows in
            contextMenu(for: rows)
        } primaryAction: { rows in
            if rows.count == 1, let d = model.resumeDraft() { openWindow(id: "compose", value: d) }
        }
        // ↑↓는 List가 처리한다. Space/⇧Space는 본문을 넘기고, 끝에서 다음/이전 메일로 (S-019).
        // 임시 보관함에서 Return은 초안을 이어서 쓴다 (S-022).
        .onKeyPress(.return) {
            guard let d = model.resumeDraft() else { return .ignored }
            openWindow(id: "compose", value: d)
            return .handled
        }
        .onKeyPress(.space, phases: .down) { press in
            let down = !press.modifiers.contains(.shift)
            Task { await model.pageOrAdvance(down: down) }
            return .handled
        }
        .overlay { emptyState }
        // 오프라인이면 목록 위에 안내 막대 (S-026)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if model.isOffline { OfflineBar() }
                if model.listFilter.isActive { FilterBar() }
            }
        }
        .navigationTitle(model.selectedFolderID == FolderOrder.flaggedID ? "깃발 표시" : (model.selectedFolder?.displayName ?? "메일"))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                FilterMenu()
                SortMenu()
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

    /// 오른쪽 클릭 메뉴. 클릭한 줄이 선택 밖이면 그 줄만, 안이면 고른 줄 전체에 적용한다.
    @ViewBuilder
    private func contextMenu(for rows: Set<String>) -> some View {
        if !rows.isEmpty {
            let single = rows.count == 1 ? model.messages.first(where: { rows.contains($0.id) }) : nil
            Button("답장") { if let m = single { compose(.reply, for: m) } }
                .disabled(single == nil)
            Button("전체 답장") { if let m = single { compose(.replyAll, for: m) } }
                .disabled(single == nil)
            Button("전달") { if let m = single { compose(.forward, for: m) } }
                .disabled(single == nil)
            Divider()
            Button("읽음/읽지 않음 전환") { act(rows) { await model.toggleReadSelected() } }
            Button("깃발 달기/떼기") { act(rows) { await model.toggleFlagSelected() } }
            Divider()
            Menu("이동") {
                ForEach(model.moveTargets) { target in
                    Button(target.title) {
                        act(rows) { await model.moveSelected(to: target.id, undoManager: undoManager, undoName: "이동") }
                    }
                }
            }
            Button("보관") { act(rows) { await model.archiveSelected(undoManager: undoManager) } }
            Button(model.selectedFolder?.kind == "junkemail" ? "정크 아님" : "정크 메일로 표시") {
                act(rows) { await model.toggleJunkSelected(undoManager: undoManager) }
            }
            Button("지우기", role: .destructive) { act(rows) { await model.deleteSelected(undoManager: undoManager) } }
        }
    }

    /// 메뉴를 연 줄들을 고른 뒤 동작한다.
    private func act(_ rows: Set<String>, _ action: @escaping () async -> Void) {
        if model.selection != rows { model.selection = rows }
        Task { await action() }
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
    /// 다른 폴더의 메일이면 그 폴더 이름 (모든 폴더 검색, 깃발 표시)
    var folderTag: String? = nil

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
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("깃발")
                    }
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
                HStack(spacing: Space.xs) {
                    Text(message.title)
                        .lineLimit(1)
                    if let folderTag {
                        Spacer(minLength: Space.xs)
                        Text(folderTag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.xs)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(message.bodyPreview ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

/// 대화 한 줄 (S-025): 참여자, 메일 수, 제목, 최근 메일 미리보기.
struct ConversationRow: View {
    let conversation: Conversation
    let me: String?

    var body: some View {
        let latest = conversation.latest
        HStack(alignment: .top, spacing: Space.sm) {
            Circle()
                .fill(conversation.isUnread ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear))
                .frame(width: 8, height: 8)
                .padding(.top, Space.xs)
                .accessibilityLabel(conversation.isUnread ? "읽지 않음" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(conversation.participants(me: me).joined(separator: ", "))
                        .fontWeight(conversation.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if conversation.count > 1 {
                        Text("\(conversation.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.xs)
                            .background(.quaternary, in: Capsule())
                            .accessibilityLabel("메일 \(conversation.count)통")
                    }
                    Spacer(minLength: Space.xs)
                    if conversation.messages.contains(where: \.isFlagged) {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("깃발")
                    }
                    if conversation.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("첨부 있음")
                    }
                    Text(latest.receivedDateTime.map { MailDate.listLabel($0) } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(latest.title)
                    .lineLimit(1)
                Text(latest.bodyPreview ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

/// 오프라인 안내 (S-026): 경고가 아니라 안내라서 회색으로 둔다.
struct OfflineBar: View {
    @Environment(AppModel.self) private var model
    @State private var retrying = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
            Text("오프라인 · 저장된 메일을 보여 줍니다")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            Button {
                Task {
                    retrying = true
                    await model.retryConnection()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView().controlSize(.small) } else { Text("다시 연결") }
            }
            .controlSize(.small)
            .disabled(retrying)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

/// 목록 필터 메뉴 (S-041). 켜져 있으면 깔때기가 채워진다.
struct FilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Toggle("읽지 않음", isOn: $model.listFilter.unread)
            Toggle("깃발", isOn: $model.listFilter.flagged)
            Toggle("첨부 파일 있음", isOn: $model.listFilter.hasAttachments)
            Toggle("멘션(@)", isOn: $model.listFilter.mentionsMe)
            Toggle("높은 우선순위", isOn: $model.listFilter.highImportance)
            Toggle("받는 사람 또는 참조에 내가 있는 메일", isOn: $model.listFilter.toOrCcMe)
            Picker("받은 날짜", selection: $model.listFilter.received) {
                Text("전체").tag(MailFilter.Period?.none)
                ForEach(MailFilter.Period.allCases, id: \.self) { p in
                    Text(p.label).tag(MailFilter.Period?.some(p))
                }
            }
            Picker("범주", selection: $model.listFilter.category) {
                Text("전체").tag(String?.none)
                ForEach(model.categories, id: \.self) { c in
                    Text(c).tag(String?.some(c))
                }
            }
            .disabled(model.categories.isEmpty)
            Divider()
            Button("모든 필터 해제") { model.listFilter = MailFilter() }
                .disabled(!model.listFilter.isActive)
        } label: {
            Label("필터", systemImage: model.listFilter.isActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(model.listFilter.isActive ? "필터: " + model.listFilter.labels.joined(separator: ", ") : "필터")
    }
}

/// 정렬 기준 메뉴 (S-042)
struct SortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("정렬 기준", selection: $model.listSort.key) {
                ForEach(MailSort.Key.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("순서", selection: $model.listSort.descending) {
                Text(model.listSort.key == .date ? "새로운 항목 우선" : "내림차순").tag(true)
                Text(model.listSort.key == .date ? "오래된 항목 우선" : "오름차순").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("정렬", systemImage: "arrow.up.arrow.down")
        }
        .help("정렬 기준: \(model.listSort.key.label)")
    }
}

/// 켜진 필터 (S-041): 무엇으로 거르고 있는지와 해제 버튼
struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text(model.listFilter.labels.joined(separator: " · "))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Space.xs)
            Button("해제") { model.listFilter = MailFilter() }
                .controlSize(.small)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}
