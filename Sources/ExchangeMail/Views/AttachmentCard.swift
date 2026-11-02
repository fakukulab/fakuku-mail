import AppKit
import ExchangeMailKit
import SwiftUI
import UniformTypeIdentifiers

/// 첨부 한 개를 Outlook처럼 보이는 카드 (작성 창, 받은 메일 머리글).
/// 파일 종류 아이콘, 이름, 크기, 오른쪽 ⌄ 메뉴(미리 보기, 열기, 다운로드, 제거). 누르면 미리 보기.
struct AttachmentCard: View {
    let name: String
    let size: Int?
    var preview: (() -> Void)?
    var open: (() -> Void)?
    var save: (() -> Void)?
    var remove: (() -> Void)?

    private var icon: NSImage {
        let ext = (name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: 200, alignment: .leading)
            Menu {
                actions
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help(L("첨부 동작"))
        }
        .font(.callout)
        .padding(.leading, Space.sm)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.sm)
        .background(.background, in: RoundedRectangle(cornerRadius: Space.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Space.sm, style: .continuous).strokeBorder(.separator))
        .contentShape(Rectangle())
        .onTapGesture { (preview ?? open)?() }
        .contextMenu { actions }
        .help(L("\(name) - 누르면 미리 보기"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var actions: some View {
        if let preview { Button(L("미리 보기"), action: preview) }
        if let open { Button(L("열기"), action: open) }
        if let save { Button(L("다운로드…"), action: save) }
        if let remove {
            Divider()
            Button(L("제거"), role: .destructive, action: remove)
        }
    }
}

/// 첨부 카드를 한 줄에 늘어놓고, 넘치면 가로로 스크롤한다.
struct AttachmentStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) { content }
                .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }
}

enum AttachmentFiles {
    /// 로컬 파일을 다른 곳에 저장한다 (다운로드…).
    static func saveCopy(of url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FilenameEncoder.normalize(url.lastPathComponent)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }
}
