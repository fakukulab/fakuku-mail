import AppKit
import ExchangeMailKit
import SwiftUI

/// 파일 > 메일상자 가져오기… (S-053): 내 Mac에 보관한 .mbox·.eml을 읽기 전용으로 본다.
/// 서버에 닿지 않는다: 로그인 없이, 오프라인에서도 열린다. 본문은 받은 메일과 같은 안전 규칙(스크립트 끔, 원격 그림 막음).
struct ArchiveWindow: View {
    let url: URL?
    @State private var mails: [ArchivedMail]?
    @State private var failure: String?
    @State private var selection: ArchivedMail.ID?
    @State private var searchText = ""
    @AppStorage(Prefs.bodyFontFamily) private var bodyFamily = ""
    @AppStorage(Prefs.bodyFontSize) private var bodySize = 14
    @AppStorage(Prefs.plainMonospace) private var plainMonospace = false
    @AppStorage(Prefs.quoteColors) private var quoteColors = true
    @AppStorage(Prefs.quoteColor1) private var quote1 = Prefs.defaultQuoteColors[0]
    @AppStorage(Prefs.quoteColor2) private var quote2 = Prefs.defaultQuoteColors[1]
    @AppStorage(Prefs.quoteColor3) private var quote3 = Prefs.defaultQuoteColors[2]

    private var readingStyle: ReadingStyle {
        ReadingStyle(family: bodyFamily, size: bodySize, plainMonospace: plainMonospace, quoteColors: quoteColors,
                     quote: [quote1, quote2, quote3])
    }

    private var filtered: [ArchivedMail] {
        let all = mails ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.subject.lowercased().contains(q) || $0.from.lowercased().contains(q) || $0.to.lowercased().contains(q)
                || ($0.text ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        content
            .navigationTitle(url?.lastPathComponent ?? "메일 파일")
            .navigationSubtitle(mails.map { "\($0.count)통 · 읽기 전용" } ?? "")
            .task(id: url) { await load() }
            .noInitialFocus()
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            ContentUnavailableView("메일 파일을 열 수 없습니다", systemImage: "tray.and.arrow.down",
                                   description: Text(failure))
        } else if let mails {
            if mails.isEmpty {
                ContentUnavailableView("메일 없음", systemImage: "tray",
                                       description: Text("이 파일에서 메일을 찾지 못했습니다. mbox나 eml 파일인지 확인하세요."))
            } else {
                NavigationSplitView {
                    list
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                } detail: {
                    if let mail = mails.first(where: { $0.id == selection }) {
                        ArchivedMailView(mail: mail, css: readingStyle.css)
                    } else {
                        ContentUnavailableView("메일을 고르세요", systemImage: "envelope")
                    }
                }
                .searchable(text: $searchText, placement: .sidebar, prompt: "이 파일에서 검색")
            }
        } else {
            ProgressView("메일을 읽는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        List(filtered, selection: $selection) { mail in
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(MailArchive.displayName(mail.from))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: Space.sm)
                    if let date = mail.date {
                        Text(date, format: .dateTime.year().month().day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: Space.xs) {
                    Text(mail.title)
                        .lineLimit(1)
                    if mail.attachments.contains(where: { !$0.isInline }) {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("첨부 있음")
                    }
                }
                Text(MailArchive.preview(mail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, Space.xs)
            .tag(mail.id)
        }
        .overlay {
            if filtered.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
    }

    private func load() async {
        guard let url else {
            failure = "열 파일이 없습니다."
            return
        }
        do {
            let list = try await Task.detached(priority: .userInitiated) { try ArchiveFile.load(url) }.value
            mails = list
            selection = list.first?.id
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// 보관한 메일 한 통: 머리글, 첨부, 본문
struct ArchivedMailView: View {
    let mail: ArchivedMail
    let css: String
    @Environment(\.openWindow) private var openWindow

    private var files: [ArchivedAttachment] { mail.attachments.filter { !$0.isInline } }

    private var page: String {
        let html = MailArchive.inlineImages(mail)
        let body = html.map { MailMessage.Body(contentType: "html", content: $0) }
            ?? MailMessage.Body(contentType: "text", content: mail.text ?? "")
        // 보관 파일은 오래 두고 보는 것이므로 원격 그림은 늘 막는다 (보낸 사람에게 열람이 알려지지 않게).
        return MailContent.page(body: body, remote: .blocked) + css
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(mail.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.sm, verticalSpacing: Space.xs) {
                    row("보낸 사람", mail.from)
                    row("받는 사람", mail.to)
                    if !mail.cc.isEmpty { row("참조", mail.cc) }
                    if let date = mail.date {
                        row("날짜", date.formatted(date: .long, time: .shortened))
                    }
                }
                .font(.callout)
                if !files.isEmpty {
                    AttachmentStrip {
                        ForEach(files) { file in
                            AttachmentCard(name: file.name, size: file.data.count,
                                           open: { ArchivedFiles.open(file) },
                                           save: { ArchivedFiles.save(file) })
                        }
                    }
                }
            }
            .gridProbe("archive-header", area: "archive-message")
            .padding(Space.margin)
            Divider()
            // 끝 클로저는 onPrint(인자 없음)에 붙으므로 onMailto는 이름을 붙여 넘긴다.
            HTMLView(html: page, onMailto: { url in
                openWindow(id: "compose", value: ComposeDraft.mailto(url))
            })
        }
        .gridArea("archive-message")
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

/// 보관한 메일의 첨부 열기·저장
enum ArchivedFiles {
    static func open(_ file: ArchivedAttachment) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ExchangeMail-archive/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: FilenameEncoder.normalize(safeName(file.name)))
        guard (try? file.data.write(to: target)) != nil else { return }
        NSWorkspace.shared.open(target)
    }

    static func save(_ file: ArchivedAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FilenameEncoder.normalize(safeName(file.name))
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? file.data.write(to: target)
    }

    /// 파일 이름에 경로 구분자가 들어 있으면 바꾼다 (보관 파일은 남이 만든 것일 수 있다).
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "첨부" : cleaned
    }
}
