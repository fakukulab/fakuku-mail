import ExchangeMailKit
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @Environment(\.undoManager) var undoManager
    /// 보기 > 대화별로 정리 (S-025)
    @AppStorage("list.threaded") private var threaded = true

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if threaded {
                // 대화 한 줄의 tag는 대화의 최근 메일 id다.
                let conversations = model.conversations
                ForEach(conversations) { c in
                    ConversationRow(conversation: c, me: model.auth.email, vip: model.mailboxes.vip(for: c.latest))
                        .tag(c.latest.id)
                        .draggable(model.dragPayload(for: c.latest.id))
                        .onAppear {
                            if c.id == conversations.last?.id { Task { await model.loadMore() } }
                        }
                }
            } else {
                ForEach(model.messages) { m in
                    MessageRow(message: m, folderTag: model.folderTag(for: m), vip: model.mailboxes.vip(for: m))
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
        // 오른쪽 클릭은 고른 줄 전체에 (S-027). 두 번 클릭은 별도 창으로, 초안이면 이어서 쓰기 (S-043, S-022).
        .contextMenu(forSelectionType: String.self) { rows in
            contextMenu(for: rows)
        } primaryAction: { rows in
            if rows.count == 1 { openInWindow() }
        }
        // ↑↓는 List가 처리한다. Space/⇧Space는 본문을 넘기고, 끝에서 다음/이전 메일로 (S-019).
        // Return은 두 번 클릭과 같다.
        .onKeyPress(.return) {
            openInWindow() ? .handled : .ignored
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
                // 지운 편지함 비우기, 모두 읽음 같은 오래 걸리는 일 (M17)
                if let progress = model.progressText {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text(progress)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.sm)
                    .background(.bar)
                }
                if model.listFilter.isActive { FilterBar() }
            }
        }
        .navigationTitle(model.listTitle)
        .navigationSubtitle(subtitle)
        .toolbar(id: "mail") { listToolbar }
    }

    /// 고른 메일을 새 창에서 연다. 초안은 작성 창에서. 열었으면 true.
    @discardableResult
    private func openInWindow() -> Bool {
        switch model.openTarget() {
        case .compose(let draft): openWindow(id: "compose", value: draft)
        case .message(let id): openWindow(id: "message", value: id)
        case nil: return false
        }
        return true
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
            Button("새 창에서 열기") {
                if let m = single {
                    if model.selectedMessageID != m.id { model.selectedMessageID = m.id }
                    if model.selectedFolder?.kind == "drafts" {
                        Task {
                            await model.loadDetail()
                            openInWindow()
                        }
                    } else {
                        openWindow(id: "message", value: m.id)
                    }
                }
            }
            .disabled(single == nil)
            // VIP (S-045)
            if let m = single {
                if model.mailboxes.vip(for: m) == nil {
                    Button("보낸 사람을 VIP로 지정…") { model.editVIP(for: m) }
                } else {
                    Button("VIP 이름·아이콘 변경…") { model.editVIP(for: m) }
                    Button("VIP에서 빼기") {
                        if let address = m.from?.emailAddress.address { model.removeVIP(address: address) }
                    }
                }
            }
            Divider()
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
    /// 보낸 사람이 VIP면 그 사람의 아이콘을 이름 앞에 (S-045)
    var vip: VIP? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle()
                .fill(message.isUnread ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear))
                .frame(width: 8, height: 8)
                .padding(.top, Space.xs)
                .accessibilityLabel(message.isUnread ? "읽지 않음" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    if let vip {
                        VIPBadge(vip: vip)
                    }
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
    /// 마지막 메일을 VIP가 보냈으면 (S-045)
    var vip: VIP? = nil

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
                    if let vip {
                        VIPBadge(vip: vip)
                    }
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
    /// 환경이 아니라 직접 받는다: 도구 막대 사용자화 시트는 항목을 창의 환경 밖에서 그린다 (S-044).
    let model: AppModel

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
    /// 환경이 아니라 직접 받는다: 도구 막대 사용자화 시트는 항목을 창의 환경 밖에서 그린다 (S-044).
    let model: AppModel

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
