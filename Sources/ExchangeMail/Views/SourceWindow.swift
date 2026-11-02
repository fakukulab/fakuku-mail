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
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                }
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
