import AppKit
import ExchangeMailKit
import SwiftUI

/// 작성 창: 새 메시지, 답장, 전체 답장, 전달.
struct ComposeView: View {
    let draft: ComposeDraft
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage("fixEnabled") private var fixDefault = true
    @AppStorage("fixImagesAsAttachments") private var imagesAsAttachments = true

    @State private var editor = RichTextController()
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showBcc = false
    @State private var subject = ""
    @State private var files: [URL] = []
    @State private var forwarded: [FileAttachment] = []
    @State private var signatureID: UUID?
    @State private var fixEnabled = true
    @State private var sending = false
    @State private var error: String?
    @State private var errorTitle = "보낼 수 없습니다"
    @State private var didSetUp = false
    @State private var dropTargeted = false
    @FocusState private var focus: Field?

    private enum Field { case to, cc, bcc, subject }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FormatToolbar(controller: editor)
            Divider()
            RichTextEditor(controller: editor)
            if !files.isEmpty || !forwarded.isEmpty || movedImageCount > 0 {
                Divider()
                attachmentBar
            }
        }
        .navigationTitle(subject.isEmpty ? draft.kind.label : subject)
        .toolbar { toolbar }
        .alert(errorTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        // 창 어디에 놓아도 첨부가 된다 (S-017). 편집기 위도 여기로 온다 (RichTextController.makeWebView).
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls.filter(\.isFileURL))
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
        .task { await setUp() }
    }

    // MARK: 머리글

    private var header: some View {
        VStack(spacing: 0) {
            row("받는 사람:") {
                TextField("받는 사람", text: $to, prompt: Text("이름 <주소>, 주소…"))
                    .focused($focus, equals: .to)
            }
            Divider()
            row("참조:") {
                HStack(spacing: Space.sm) {
                    TextField("참조", text: $cc)
                        .focused($focus, equals: .cc)
                    if !showBcc {
                        Button("숨은 참조") {
                            showBcc = true
                            focus = .bcc
                        }
                        .buttonStyle(.borderless)
                        .help("숨은 참조 칸 보이기")
                    }
                }
            }
            if showBcc {
                Divider()
                row("숨은 참조:") {
                    TextField("숨은 참조", text: $bcc)
                        .focused($focus, equals: .bcc)
                }
            }
            Divider()
            row("제목:") {
                TextField("제목", text: $subject)
                    .focused($focus, equals: .subject)
            }
            Divider()
            HStack(spacing: Space.lg) {
                Picker("서명:", selection: $signatureID) {
                    Text("없음").tag(UUID?.none)
                    if !model.signatures.signatures.isEmpty { Divider() }
                    ForEach(model.signatures.signatures) { s in
                        Text(s.name).tag(UUID?.some(s.id))
                    }
                }
                .fixedSize()
                .onChange(of: signatureID) { _, id in
                    guard didSetUp else { return }
                    editor.replaceSignature(blockHTML: SignatureComposer.block(for: model.signatures.signature(id: id)))
                }
                Spacer()
                Toggle("첨부 보정", isOn: $fixEnabled)
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

    private var movedImageCount: Int {
        fixEnabled && imagesAsAttachments ? HTMLProcessor.bodyImageCount(in: editor.html) : 0
    }

    private var attachmentBar: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !files.isEmpty || !forwarded.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(files, id: \.self) { url in
                            AttachmentChip(name: FilenameEncoder.normalize(url.lastPathComponent),
                                           size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil) {
                                files.removeAll { $0 == url }
                            }
                        }
                        ForEach(forwarded) { a in
                            AttachmentChip(name: FilenameEncoder.normalize(a.name), size: a.size) {
                                forwarded.removeAll { $0.id == a.id }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("파일 첨부", systemImage: "paperclip") { attach() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("파일 첨부 (⇧⌘A)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await send() }
            } label: {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Label("보내기", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(sending)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("보내기 (⇧⌘D)")
        }
    }

    // MARK: 동작

    private func setUp() async {
        guard !didSetUp else { return }
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        showBcc = !draft.bcc.isEmpty
        subject = draft.subject
        fixEnabled = fixDefault
        let sig = model.signatures.defaultSignature(kind: draft.kind, account: model.auth.email)
        signatureID = sig?.id
        editor.setHTML("<div><br></div>" + SignatureComposer.block(for: sig) + draft.quoteHTML)
        editor.onFileDrop = { urls in addFiles(urls) }
        didSetUp = true
        if draft.to.isEmpty {
            focus = .to
        } else {
            editor.focusStart()
        }
        if let source = draft.forwardAttachmentsFrom {
            do {
                forwarded = try await model.service.attachments(messageID: source).filter { $0.isListed && $0.isFile }
            } catch {
                errorTitle = "첨부를 가져오지 못했습니다"
                self.error = "원본 첨부를 가져오지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    /// 파일 선택 창과 끌어다 놓기가 같이 쓴다. 같은 파일은 한 번만, 폴더는 건너뛴다.
    private func addFiles(_ urls: [URL]) {
        let result = AttachmentList.merge(files, adding: urls)
        files = result.files
        if !result.skipped.isEmpty {
            errorTitle = "첨부할 수 없습니다"
            error = "폴더는 첨부할 수 없습니다: \(result.skipped.joined(separator: ", ")). 압축한 뒤 첨부하세요."
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    private func send() async {
        errorTitle = "보낼 수 없습니다"
        sending = true
        defer { sending = false }
        let input = ComposeSender.Input(
            from: MailAddress(name: model.auth.displayName, address: model.auth.email ?? ""),
            to: to, cc: cc, bcc: showBcc ? bcc : "", subject: subject, bodyHTML: editor.html,
            files: files,
            extraAttachments: forwarded.compactMap { a in
                a.data.map { OutgoingAttachment(filename: a.name, mimeType: a.contentType ?? "application/octet-stream", data: $0) }
            },
            draft: draft, fixEnabled: fixEnabled)
        do {
            let mime = try ComposeSender.build(input, options: ComposeSender.defaultOptions())
            try await model.service.sendMIME(mime)
            dismiss()
        } catch {
            self.error = error.localizedDescription
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
