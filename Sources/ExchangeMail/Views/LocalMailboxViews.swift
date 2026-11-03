import AppKit
import ExchangeMailKit
import SwiftUI

/// 나의 Mac에 (S-055): 가져온 메일상자의 목록 (메인 창 가운데 열).
/// 서버에 닿지 않는다: 로그인 상태나 네트워크와 상관없이 이 Mac의 파일에서 읽는다.
struct LocalMailList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.localBoxes
        let box = model.selectedLocalBox
        // 검색은 메인 창 도구 막대의 검색 칸 (글자를 넣는 대로 거른다)
        let shown = store.filtered(model.searchText)
        Group {
            if let failure = store.failure {
                ContentUnavailableView(L("메일상자를 열 수 없습니다"), systemImage: "externaldrive.badge.xmark",
                                       description: Text(failure))
            } else if store.isLoading {
                ProgressView(L("메일을 읽는 중…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.mails.isEmpty {
                ContentUnavailableView(L("메일 없음"), systemImage: "tray",
                                       description: Text(L("이 메일상자에 메일이 없습니다.")))
            } else {
                List(shown, selection: $store.selection) { mail in
                    ArchivedMailRow(mail: mail)
                        .tag(mail.id)
                }
                .overlay {
                    if shown.isEmpty { ContentUnavailableView.search(text: model.searchText) }
                }
            }
        }
        // 창 제목은 목록 열(MessageListView)이 model.listTitle로 단다.
        .accessibilityLabel(box?.name ?? L("나의 Mac에"))
    }
}

/// 가져온 메일 한 줄: 보낸 사람, 날짜, 제목, 첨부 표시, 미리보기
struct ArchivedMailRow: View {
    let mail: ArchivedMail

    var body: some View {
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
                        .accessibilityLabel(L("첨부 있음"))
                }
            }
            Text(MailArchive.preview(mail))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, Space.xs)
    }
}

/// 나의 Mac에 상자에서 고른 메일 (메인 창 오른쪽 열)
struct LocalMailDetail: View {
    @Environment(AppModel.self) private var model
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

    var body: some View {
        if let mail = model.localBoxes.selectedMail {
            ArchivedMailView(mail: mail, css: readingStyle.css)
        } else {
            ContentUnavailableView(L("메일을 고르세요"), systemImage: "envelope")
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
                    row(L("보낸 사람"), mail.from)
                    row(L("받는 사람"), mail.to)
                    if !mail.cc.isEmpty { row(L("참조"), mail.cc) }
                    if let date = mail.date {
                        row(L("날짜"), date.formatted(date: .long, time: .shortened))
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
            .appending(path: "FAKUKUMail-archive/\(UUID().uuidString)", directoryHint: .isDirectory)
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
        return cleaned.isEmpty ? L("첨부") : cleaned
    }
}
