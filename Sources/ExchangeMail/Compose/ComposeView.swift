import AppKit
import ExchangeMailKit
import SwiftUI

/// 작성 창: 새 메시지, 답장, 전체 답장, 전달. 상태와 동작은 ComposeModel에 있다.
struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage("fixEnabled") private var fixDefault = true
    @AppStorage("fixImagesAsAttachments") private var imagesAsAttachments = true

    @State private var compose: ComposeModel
    @State private var dropTargeted = false
    @State private var showSchedule = false
    /// 보내기 취소를 기다리는 초 (설정 > 보내기, S-036)
    @AppStorage("send.undoDelay") private var undoDelay = 10
    @FocusState private var focus: Field?

    private enum Field { case to, cc, bcc, subject }

    init(draft: ComposeDraft) {
        _compose = State(initialValue: ComposeModel(draft: draft))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let left = compose.sendCountdown {
                UndoSendBar(seconds: left) { compose.cancelSend() }
                Divider()
            }
            FormatToolbar(controller: compose.editor)
            Divider()
            RichTextEditor(controller: compose.editor)
            if !compose.files.isEmpty || !compose.forwarded.isEmpty || movedImageCount > 0 || compose.uploadFraction != nil {
                Divider()
                attachmentBar
            }
        }
        .navigationTitle(compose.windowTitle)
        .navigationSubtitle(draftStatus)
        .toolbar { toolbar }
        // 포맷 메뉴가 이 창의 편집기에 동작한다 (M17).
        .focusedSceneValue(\.richTextEditor, compose.editor)
        .alert(compose.errorTitle, isPresented: Binding(get: { compose.error != nil },
                                                         set: { if !$0 { compose.error = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(compose.error ?? "")
        }
        // 창 어디에 놓아도 첨부가 된다 (S-017). 편집기 위도 여기로 온다 (RichTextController.makeWebView).
        .dropDestination(for: URL.self) { urls, _ in
            compose.addFiles(urls.filter(\.isFileURL))
            return true
        } isTargeted: { dropTargeted = $0 }
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

    private var header: some View {
        @Bindable var compose = compose
        return VStack(spacing: 0) {
            row("받는 사람:") {
                TextField("받는 사람", text: $compose.to, prompt: Text("이름 <주소>, 주소…"))
                    .focused($focus, equals: .to)
                    .addressSuggestions(for: compose.to, from: model.addressBook)
            }
            Divider()
            row("참조:") {
                HStack(spacing: Space.sm) {
                    TextField("참조", text: $compose.cc)
                        .focused($focus, equals: .cc)
                        .addressSuggestions(for: compose.cc, from: model.addressBook)
                    if !compose.showBcc {
                        Button("숨은 참조") {
                            compose.showBcc = true
                            focus = .bcc
                        }
                        .buttonStyle(.borderless)
                        .help("숨은 참조 칸 보이기")
                    }
                }
            }
            if compose.showBcc {
                Divider()
                row("숨은 참조:") {
                    TextField("숨은 참조", text: $compose.bcc)
                        .focused($focus, equals: .bcc)
                        .addressSuggestions(for: compose.bcc, from: model.addressBook)
                }
            }
            Divider()
            row("제목:") {
                TextField("제목", text: $compose.subject)
                    .focused($focus, equals: .subject)
            }
            Divider()
            HStack(spacing: Space.lg) {
                Picker("서명:", selection: $compose.signatureID) {
                    Text("없음").tag(UUID?.none)
                    if !model.signatures.signatures.isEmpty { Divider() }
                    ForEach(model.signatures.signatures) { s in
                        Text(s.name).tag(UUID?.some(s.id))
                    }
                }
                .fixedSize()
                .onChange(of: compose.signatureID) { _, _ in compose.signatureChanged(app: model) }
                Spacer()
                Toggle("첨부 보정", isOn: $compose.fixEnabled)
                    .toggleStyle(.checkbox)
                    .help("본문 그림을 일반 첨부로 보내고, 한글 파일명을 Windows·Outlook에서 읽히게 기록합니다. 이 메일에만 적용됩니다.")
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.sm)
        }
        .textFieldStyle(.plain)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            content()
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
    }

    // MARK: 첨부 막대

    private var movedImageCount: Int { compose.movedImageCount(imagesAsAttachments: imagesAsAttachments) }

    private var attachmentBar: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !compose.files.isEmpty || !compose.forwarded.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(compose.files, id: \.self) { url in
                            AttachmentChip(name: FilenameEncoder.normalize(url.lastPathComponent),
                                           size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil) {
                                compose.removeFile(url)
                            }
                        }
                        ForEach(compose.forwarded) { a in
                            AttachmentChip(name: FilenameEncoder.normalize(a.name), size: a.size) {
                                compose.removeForwarded(a)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            if let fraction = compose.uploadFraction {
                ProgressView(value: fraction) {
                    Text(compose.uploadStatus ?? "큰 첨부 올리는 중")
                        .font(.callout)
                }
            } else if compose.hasLargeAttachments {
                Label("큰 첨부는 따로 올려 보냅니다. 보내기를 누른 뒤 창 제목 아래에서 진행률을 볼 수 있습니다.",
                      systemImage: "icloud.and.arrow.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if movedImageCount > 0 {
                Label("본문 그림 \(movedImageCount)개가 일반 첨부로 나갑니다. 서명 그림은 본문에 남습니다.",
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
        if compose.savingDraft { return "초안 저장 중…" }
        if let date = compose.lastDraftSave {
            return "초안 저장됨 \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "ko_KR"))))"
        }
        return compose.savedDraftID != nil ? "임시 보관함의 초안" : ""
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("삭제", systemImage: "trash") {
                Task {
                    await compose.discard(app: model)
                    dismiss()
                }
            }
            .help("이 메일과 저장된 초안을 버립니다")
            Button("초안 저장", systemImage: "square.and.arrow.down") {
                Task { await compose.saveDraft(app: model, force: true) }
            }
            .keyboardShortcut("s")
            .disabled(compose.savingDraft)
            .help("임시 보관함에 저장 (⌘S)")
        }
        ToolbarItemGroup {
            Button("파일 첨부", systemImage: "paperclip") { attach() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("파일 첨부 (⇧⌘A)")
            Button("나중에 보내기…", systemImage: "clock") { showSchedule = true }
                .keyboardShortcut("d", modifiers: [.command, .shift, .option])
                .disabled(compose.sending)
                .help("나중에 보내기 (⌥⇧⌘D)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { if await compose.send(app: model, undoDelay: undoDelay) { dismiss() } }
            } label: {
                if compose.sending {
                    ProgressView().controlSize(.small)
                } else {
                    Label("보내기", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(compose.sending)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("보내기 (⇧⌘D)")
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
struct AttachmentChip: View {
    let name: String
    let size: Int?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
            if let size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            Button("빼기", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("첨부에서 빼기")
        }
        .font(.callout)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(.quaternary, in: Capsule())
    }
}

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
            Text("\(seconds)초 뒤에 보냅니다")
                .font(.callout)
                .monospacedDigit()
            Spacer()
            Button("보내기 취소", action: cancel)
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
            Text("나중에 보내기")
                .font(.headline)
            ForEach(ScheduledSend.presets(), id: \.date) { preset in
                Button(preset.title) { schedule(preset.date) }
                    .buttonStyle(.link)
            }
            Divider()
            DatePicker("날짜와 시각", selection: $date, in: Date().addingTimeInterval(60)...,
                       displayedComponents: [.date, .hourAndMinute])
            Text("Exchange가 이 시각에 보냅니다. 그때 Mac이 꺼져 있어도 됩니다. 보내기 전에는 보낼 편지함에서 볼 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("예약") { schedule(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ScheduledSend.isValid(date))
            }
        }
        .padding(Space.margin)
        .frame(width: 360)
    }
}
