import AppKit
import ExchangeMailKit
import SwiftUI

/// 보기 > 원본 보기 (⌥⌘U, M17): 메일의 원본 MIME(모든 헤더와 본문)을 고정폭 글자로 보인다.
struct SourceWindow: View {
    let messageID: String
    @Environment(AppModel.self) private var model
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        Group {
            if let text {
                // 원본은 수백 KB가 넘기 쉬워 SwiftUI Text로는 그려지지 않는다(흰 화면). AppKit 글 보기를 쓴다.
                PlainTextView(text: text)
            } else if let failure {
                ContentUnavailableView("원본을 불러올 수 없습니다", systemImage: "doc.text.magnifyingglass",
                                       description: Text(failure))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("원본")
        .task {
            do {
                let data = try await model.service.mimeContent(id: messageID)
                // 아주 큰 메일(첨부)은 앞부분만 보인다.
                let head = data.prefix(1_000_000)
                text = String(decoding: head, as: UTF8.self)
                    + (data.count > head.count ? "\n\n… (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) 중 앞부분)" : "")
            } catch {
                failure = error.localizedDescription
            }
        }
        .noInitialFocus()
    }
}

/// 큰 글을 빠르게 보이는 읽기 전용 글 보기 (선택·복사·찾기 가능)
struct PlainTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            view.textColor = .labelColor
            view.backgroundColor = .textBackgroundColor
            view.textContainerInset = NSSize(width: Space.lg, height: Space.lg)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let view = nsView.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
