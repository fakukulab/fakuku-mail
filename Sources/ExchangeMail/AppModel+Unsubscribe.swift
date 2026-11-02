import AppKit
import ExchangeMailKit
import Foundation
import SwiftUI

/// 받은 메일의 구독 취소 (List-Unsubscribe). 맥 Mail의 "구독 취소" 막대와 같다.
extension AppModel {

    /// 한 번에 끝나는 웹 구독 취소(RFC 8058)는 POST, 아니면 구독 취소 메일을 보내고, 그것도 없으면 웹 페이지를 연다.
    func unsubscribe(from m: MailMessage) async {
        guard let info = Unsubscribe.from(headers: m.internetMessageHeaders) else { return }
        if info.oneClick, let web = info.web {
            var request = URLRequest(url: web)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            do {
                let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    noticeMessage = L("구독 취소를 요청했습니다. 처리되기까지 며칠 걸릴 수 있습니다.")
                    return
                }
            } catch {
                // 아래 방법으로 이어서 시도한다.
            }
        }
        if let parts = info.mailtoParts, let me = auth.email {
            let input = ComposeSender.Input(
                from: MailAddress(name: auth.displayName, address: me), to: parts.to, cc: "", bcc: "",
                subject: parts.subject, bodyHTML: "<p>Unsubscribe</p>", files: [], extraAttachments: [],
                draft: ComposeDraft(), fixEnabled: false)
            do {
                let plan = try ComposeSender.prepare(input, options: .off, forDraft: false)
                try await service.sendMIME(plan.mime)
                noticeMessage = L("\(parts.to)에 구독 취소 메일을 보냈습니다.")
            } catch {
                report(error, quietIfOffline: false)
            }
            return
        }
        if let web = info.web { NSWorkspace.shared.open(web) }
    }
}

/// 본문 위 막대: 구독 취소 헤더가 있는 메일 (본문 열, 메시지 창)
struct UnsubscribeBar: View {
    let message: MailMessage
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    @State private var busy = false

    var body: some View {
        if let info = Unsubscribe.from(headers: message.internetMessageHeaders) {
            HStack(spacing: Space.sm) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .foregroundStyle(.secondary)
                Text(L("메일링 리스트나 단체 발송으로 온 메일입니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("구독 취소…")) { confirm = true }
                    .controlSize(.small)
                    .disabled(busy)
                    .help(info.oneClick ? L("보낸 곳에 구독 취소를 바로 요청합니다")
                                        : info.mailto != nil ? L("보낸 곳에 구독 취소 메일을 보냅니다") : L("구독 취소 웹 페이지를 엽니다"))
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.sm)
            .background(.bar)
            .confirmationDialog(L("이 보낸 사람의 메일을 그만 받을까요?"), isPresented: $confirm) {
                Button(L("구독 취소")) {
                    busy = true
                    Task {
                        await model.unsubscribe(from: message)
                        busy = false
                    }
                }
                Button(L("취소"), role: .cancel) {}
            } message: {
                Text(message.from?.emailAddress.display ?? "")
            }
        }
    }
}
