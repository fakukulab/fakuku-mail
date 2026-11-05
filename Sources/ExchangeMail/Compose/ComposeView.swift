import AppKit
import ExchangeMailKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 끌어다 놓은 것에서 파일 주소를 꺼낸다 (Finder의 파일, 받은 메일의 첨부 카드). 꺼내는 대로 `add`에 넘긴다.
extension ComposeView {
    static func receiveFiles(_ providers: [NSItemProvider], add: @escaping @Sendable @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for p in files {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in add([url]) }
            }
        }
        return !files.isEmpty
    }
}

/// 작성 창: 새 메시지, 답장, 전체 답장, 전달. 상태와 동작은 ComposeModel에 있다.
struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage("fixEnabled") private var fixDefault = true
    @AppStorage("fixImagesAsAttachments") private var imagesAsAttachments = true

    @State private var compose: ComposeModel
    @State private var dropTargeted = false
    @State private var showSchedule = false
    /// 첨부 카드의 미리 보기 (Quick Look)
    @State private var previewURL: URL?
    /// 머리글 필드 (보기 메뉴와 도구 막대의 머리글 필드 단추)
    @AppStorage(Prefs.fieldCc) private var fieldCc = true
    @AppStorage(Prefs.fieldBcc) private var fieldBcc = false
    @AppStorage(Prefs.fieldReplyTo) private var fieldReplyTo = false
    @AppStorage(Prefs.fieldPriority) private var fieldPriority = true
    /// 설정 > 작성 > 다음으로 끝나지 않는 주소 표시
    @AppStorage(Prefs.highlightExternal) private var highlightExternal = false
    @AppStorage(Prefs.internalDomains) private var internalDomains = ""

    private var externalAddresses: [String] {
        guard highlightExternal else { return [] }
        return ExternalAddresses.find(in: [compose.to, compose.cc, compose.bcc], internalDomains: internalDomains)
    }
    /// 보내기 취소를 기다리는 초 (설정 > 보내기, S-036)
    @AppStorage("send.undoDelay") private var undoDelay = 10
    @FocusState private var focus: Field?

    private enum Field { case to, cc, bcc, replyTo, subject }

    init(draft: ComposeDraft) {
        _compose = State(initialValue: ComposeModel(draft: draft))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            let outside = externalAddresses
            if !outside.isEmpty {
                Divider()
                Label(L("바깥 주소: \(outside.joined(separator: ", "))"), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.sm)
                    .help(L("설정 > 작성에 적은 도메인으로 끝나지 않는 주소입니다. 받는 사람을 다시 확인하세요."))
            }
            Divider()
            // 첨부는 Outlook처럼 제목 아래, 본문 위에 카드로 (M17)
            if !compose.files.isEmpty || !compose.forwarded.isEmpty {
                attachmentCards
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.sm)
                Divider()
            }
            if let left = compose.sendCountdown {
                UndoSendBar(seconds: left) { compose.cancelSend() }
                Divider()
            }
            FormatToolbar(controller: compose.editor, showsWritingTools: false)
            Divider()
            RichTextEditor(controller: compose.editor)
            if compose.uploadFraction != nil || compose.hasLargeAttachments || movedImageCount > 0 {
                Divider()
                attachmentBar
            }
        }
        .navigationTitle(compose.windowTitle)
        .navigationSubtitle(draftStatus)
        .toolbar { toolbar }
        .quickLookPreview($previewURL)
        // 포맷 메뉴가 이 창의 편집기에 동작한다 (M17).
        .focusedSceneValue(\.richTextEditor, compose.editor)
        .alert(compose.errorTitle, isPresented: Binding(get: { compose.error != nil },
                                                         set: { if !$0 { compose.error = nil } })) {
            Button(L("확인"), role: .cancel) {}
        } message: {
            Text(compose.error ?? "")
        }
        // 창 어디에 놓아도 첨부가 된다 (S-017). 편집기 위도 여기로 온다 (RichTextController.makeWebView).
        // 파일 주소를 직접 꺼낸다: SwiftUI의 dropDestination(for: URL)은 Finder에서 끈 파일은 받지만
        // 받은 메일의 첨부 카드(앱 안에서 끈 것)는 꺼내지 못했다.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            if Self.receiveFiles(providers, add: { compose.addFiles($0) }) { return true }
            // 내용이 하나도 없는 끌기: 받은 메일의 첨부 카드를 끌면 그렇게 올 때가 있다. 마우스를 올렸던 그 첨부를 넣는다.
            // (글자나 다른 앱의 끌기처럼 내용이 있는 것에는 쓰지 않는다)
            guard !providers.isEmpty, providers.allSatisfy({ $0.registeredTypeIdentifiers.isEmpty }) else { return false }
            let app = model
            Task {
                if let url = await app.droppedAttachmentFile() { compose.addFiles([url]) }
            }
            return !providers.isEmpty
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .padding(Space.xs)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showSchedule) {
            ScheduleSheet { date in
                showSchedule = false
                Task { if await compose.schedule(app: model, at: date) { dismiss() } }
            }
        }
        .task {
            await compose.setUp(app: model, fixDefault: fixDefault)
            if compose.draft.to.isEmpty {
                focus = .to
            } else {
                compose.editor.focusStart()
            }
            // 쓰는 동안 30초마다 초안을 저장한다 (S-022). 바뀐 것이 없으면 아무것도 하지 않는다.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await compose.saveDraft(app: model)
            }
        }
        // 창을 닫으면 쓰던 것을 초안으로 남긴다. 창이 사라져도 저장은 끝까지 간다.
        .onDisappear {
            let compose = compose, app = model
            Task { await compose.windowClosed(app: app) }
        }
    }

    // MARK: 머리글

    /// 맥 Mail처럼: 레이블은 왼쪽, 구분선은 왼쪽 여백부터 창 끝까지. 참조·숨은 참조·답장 받을 사람·우선 순위는
    /// 보기 메뉴나 도구 막대의 머리글 필드 단추로 보이고 감춘다 (값이 들어 있으면 늘 보인다).
    private var header: some View {
        @Bindable var compose = compose
        return VStack(spacing: 0) {
            row(L("받는 사람:")) {
                RecipientField(title: L("받는 사람"), text: $compose.to, book: model.addressBook, focus: $focus, focusValue: .to)
            }
            rule
            if fieldCc || !compose.cc.isEmpty {
                row(L("참조:")) {
                    RecipientField(title: L("참조"), text: $compose.cc, book: model.addressBook, focus: $focus, focusValue: .cc)
                }
                rule
            }
            if fieldBcc || !compose.bcc.isEmpty {
                row(L("숨은 참조:")) {
                    RecipientField(title: L("숨은 참조"), text: $compose.bcc, book: model.addressBook, focus: $focus, focusValue: .bcc)
                }
                rule
            }
            if fieldReplyTo || !compose.replyTo.isEmpty {
                row(L("답장 받을 사람:")) {
                    RecipientField(title: L("답장 받을 사람"), text: $compose.replyTo, book: model.addressBook,
                                   focus: $focus, focusValue: .replyTo)
                }
                rule
            }
            row(L("제목:")) {
                TextField(L("제목"), text: $compose.subject, prompt: Text(""))
                    .focused($focus, equals: .subject)
                if fieldPriority || compose.importance != "normal" {
                    priorityMenu
                }
            }
            rule
            row(L("보낸 사람:")) {
                // 계정이 둘 이상이면 보낼 계정을 고른다 (M23). 답장·전달은 원래 메일의 계정이 기본.
                if model.accounts.accounts.count > 1 {
                    Picker(L("보낸 사람"), selection: $compose.accountID) {
                        ForEach(model.accounts.accounts) { account in
                            Text(Self.fromLine(account)).tag(String?.some(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: compose.accountID) { old, _ in
                        Task { await compose.accountChanged(app: model, from: old) }
                    }
                } else {
                    Text(fromLine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.lg)
                Text(L("서명:"))
                    .foregroundStyle(.secondary)
                Picker(L("서명"), selection: $compose.signatureID) {
                    Text(L("없음")).tag(UUID?.none)
                    if !model.signatures.signatures.isEmpty { Divider() }
                    ForEach(model.signatures.signatures) { s in
                        Text(s.name).tag(UUID?.some(s.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: compose.signatureID) { _, _ in compose.signatureChanged(app: model) }
            }
        }
        .textFieldStyle(.plain)
    }

    /// 계정 하나의 "이름 – 주소"
    static func fromLine(_ account: MailAccount) -> String {
        guard let name = account.auth.displayName, !name.isEmpty else { return account.email }
        return "\(name) – \(account.email)"
    }

    /// 보낸 사람: "이름 – 주소"
    private var fromLine: String {
        let email = model.auth.email ?? ""
        guard let name = model.auth.displayName, !name.isEmpty else { return email }
        return "\(name) – \(email)"
    }

    /// 우선 순위 팝업: 닫혀 있을 때는 기호(!! / ! / –)만, 누르면 "우선 순위 높음" 같은 이름이 보인다.
    /// 제목 줄 오른쪽 끝, 맥 Mail과 같은 자리.
    private var priorityMenu: some View {
        @Bindable var compose = compose
        let mark = compose.importance == "high" ? "!!" : compose.importance == "low" ? "–" : "!"
        return Menu {
            Picker(L("우선 순위"), selection: $compose.importance) {
                Text(L("!!  우선 순위 높음")).tag("high")
                Text(L("!   우선 순위 보통")).tag("normal")
                Text(L("–   우선 순위 낮음")).tag("low")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(mark)
                .fontWeight(.semibold)
                .foregroundStyle(compose.importance == "normal" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .menuStyle(.button)
        .fixedSize()
        .help(compose.importance == "high" ? L("우선 순위 높음") : compose.importance == "low" ? L("우선 순위 낮음") : L("우선 순위 보통"))
        .accessibilityLabel(L("우선 순위"))
    }

    /// 머리글 필드 단추 (도구 막대): 참조, 숨은 참조, 답장 받을 사람, 우선 순위를 보이고 감춘다.
    private var fieldsMenu: some View {
        Menu {
            Toggle(L("참조 주소 필드"), isOn: $fieldCc)
            Toggle(L("숨은 참조 주소 필드"), isOn: $fieldBcc)
            Toggle(L("답장 받을 사람 주소 필드"), isOn: $fieldReplyTo)
            Toggle(L("우선 순위 필드"), isOn: $fieldPriority)
        } label: {
            Label(L("머리글 필드"), systemImage: "list.bullet.rectangle")
        }
        .help(L("머리글 필드 보이기·감추기"))
    }

    /// 왼쪽 여백부터 창 오른쪽 끝까지 긋는 구분선 (맥 Mail)
    private var rule: some View {
        Divider().padding(.leading, Space.margin)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
            content()
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.md)
    }

    // MARK: 첨부 막대

    private var movedImageCount: Int { compose.movedImageCount(imagesAsAttachments: imagesAsAttachments) }

    /// 붙인 파일과 전달할 원본 첨부: 누르면 미리 보기, ⌄ 메뉴로 열기·다운로드·제거
    private var attachmentCards: some View {
        AttachmentStrip {
            ForEach(compose.files, id: \.self) { url in
                AttachmentCard(name: FilenameEncoder.normalize(url.lastPathComponent),
                               size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil,
                               preview: { previewURL = url },
                               open: { NSWorkspace.shared.open(url) },
                               save: { AttachmentFiles.saveCopy(of: url) },
                               remove: { compose.removeFile(url) })
            }
            ForEach(compose.forwarded) { a in
                AttachmentCard(name: FilenameEncoder.normalize(a.name), size: a.size,
                               preview: { previewURL = model.previewFile(for: a) },
                               open: { Task { await model.openAttachment(a) } },
                               save: { Task { await model.save(attachment: a) } },
                               remove: { compose.removeForwarded(a) })
            }
        }
    }

    private var attachmentBar: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let fraction = compose.uploadFraction {
                ProgressView(value: fraction) {
                    Text(compose.uploadStatus ?? L("큰 첨부 올리는 중"))
                        .font(.callout)
                }
            } else if compose.hasLargeAttachments {
                Label(L("큰 첨부는 따로 올려 보냅니다. 보내기를 누른 뒤 창 제목 아래에서 진행률을 볼 수 있습니다."),
                      systemImage: "icloud.and.arrow.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if movedImageCount > 0 {
                Label(L("본문 그림 \(movedImageCount)개가 일반 첨부로 나갑니다. 서명 그림은 본문에 남습니다."),
                      systemImage: "photo.on.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 툴바

    /// 창 제목 아래: 초안 저장 상태.
    private var draftStatus: String {
        if let status = compose.uploadStatus {
            return compose.uploadFraction.map { "\(status) · \(Int(($0 * 100).rounded()))%" } ?? status
        }
        if compose.savingDraft { return L("초안 저장 중…") }
        if let date = compose.lastDraftSave {
            return L("초안 저장됨 \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: AppLanguage.locale)))")
        }
        return compose.savedDraftID != nil ? L("임시 보관함의 초안") : ""
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button(L("삭제"), systemImage: "trash") {
                Task {
                    await compose.discard(app: model)
                    dismiss()
                }
            }
            .help(L("이 메일과 저장된 초안을 버립니다"))
            Button(L("초안 저장"), systemImage: "square.and.arrow.down") {
                Task { await compose.saveDraft(app: model, force: true) }
            }
            .keyboardShortcut("s")
            .disabled(compose.savingDraft)
            .help(L("임시 보관함에 저장 (⌘S)"))
        }
        // 맥 Mail처럼 창 도구 막대의 아이콘 단추 (⌃⌘W)
        ToolbarItem {
            Button(L("Siri로 글쓰기"), systemImage: "apple.writing.tools") { compose.editor.showWritingTools() }
                .help(L("Siri로 글쓰기"))
        }
        ToolbarItem {
            fieldsMenu
        }
        ToolbarItemGroup {
            Button(L("파일 첨부"), systemImage: "paperclip") { attach() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help(L("파일 첨부 (⇧⌘A)"))
            // 나중에 보내기는 Exchange 서버가 한다: iCloud·Gmail 계정으로 쓸 때는 끈다
            let canSchedule = compose.account(model)?.imap == nil
            Button(L("나중에 보내기…"), systemImage: "clock") { showSchedule = true }
                .keyboardShortcut("d", modifiers: [.command, .shift, .option])
                .disabled(compose.sending || !canSchedule)
                .help(canSchedule ? L("나중에 보내기 (⌥⇧⌘D)") : L("나중에 보내기는 Exchange 계정에서만 할 수 있습니다"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { if await compose.send(app: model, undoDelay: undoDelay) { dismiss() } }
            } label: {
                if compose.sending {
                    ProgressView().controlSize(.small)
                } else {
                    Label(L("보내기"), systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(compose.sending)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help(L("보내기 (⇧⌘D)"))
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            compose.addFiles(panel.urls)
        }
    }
}

/// 첨부 칩: 보낼 이름(NFC)과 크기, 빼기 버튼.
extension View {
    /// 받는 사람 칸 자동완성 (S-018). 마지막 항목으로 주소록을 찾고, 고르면 그 항목을 주소로 바꾼다.
    func addressSuggestions(for text: String, from book: AddressBookStore) -> some View {
        textInputSuggestions {
            ForEach(book.suggestions(for: text), id: \.self) { address in
                Label {
                    Text(address.editable)
                } icon: {
                    Image(systemName: "person.crop.circle")
                }
                .textInputCompletion(AddressBook.complete(text, with: address))
            }
        }
    }
}

/// 보내기 취소 막대 (S-036): 남은 초와 취소 버튼. Esc로도 취소한다.
struct UndoSendBar: View {
    let seconds: Int
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "paperplane")
                .foregroundStyle(.secondary)
            Text(L("\(seconds)초 뒤에 보냅니다"))
                .font(.callout)
                .monospacedDigit()
            Spacer()
            Button(L("보내기 취소"), action: cancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}

/// 나중에 보내기 (S-037): 프리셋이나 날짜·시각을 골라 예약한다.
struct ScheduleSheet: View {
    let schedule: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = ScheduledSend.presets().first?.date ?? Date().addingTimeInterval(3_600)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(L("나중에 보내기"))
                .font(.headline)
            ForEach(ScheduledSend.presets(), id: \.date) { preset in
                Button(preset.title) { schedule(preset.date) }
                    .buttonStyle(.link)
            }
            Divider()
            DatePicker(L("날짜와 시각"), selection: $date, in: Date().addingTimeInterval(60)...,
                       displayedComponents: [.date, .hourAndMinute])
            Text(L("Exchange가 이 시각에 보냅니다. 그때 Mac이 꺼져 있어도 됩니다. 보내기 전에는 보낼 편지함에서 볼 수 있습니다."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("취소"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("예약")) { schedule(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ScheduledSend.isValid(date))
            }
        }
        .padding(Space.margin)
        .frame(width: 360)
    }
}
