import AppIntents
import ExchangeMailKit
import Foundation
import SwiftUI

// Siri 음성 명령과 단축어 (App Intents). "시리야, 파쿠쿠 메일에서 읽지 않은 메일 몇 통이야?"
// 명령이 Siri·단축어에 보이려면 앱 안에 Metadata.appintents가 있어야 한다: build.sh가 tools/make_intents.sh로 만든다.
// 앱 타깃은 기본이 메인 액터라, 프레임워크가 부르는 타입은 nonisolated로 두고 perform만 메인 액터에서 돈다.

/// 인텐트가 쓰는 앱 모델. 앱이 켜지면 ContentView가 넣는다. 인텐트로 앱이 막 켜졌으면 잠깐 기다린다.
enum IntentModel {
    @MainActor static weak var current: AppModel?

    @MainActor
    static func ready() async throws -> AppModel {
        for _ in 0..<50 {
            if let model = current, model.isSignedIn { return model }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntentProblem.notReady
    }
}

nonisolated enum IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "FAKUKU Mail에 로그인되어 있지 않습니다. 앱을 열어 로그인해 주세요."
    }
}

/// 읽지 않은 메일 수 (받은 편지함)
nonisolated struct UnreadCountIntent: AppIntent {
    static let title: LocalizedStringResource = "읽지 않은 메일 수"
    static let description = IntentDescription("받은 편지함의 읽지 않은 메일 수를 알려 줍니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let model = try await IntentModel.ready()
        await model.loadFolders()
        let count = model.folders.first { $0.kind == "inbox" }?.unreadItemCount ?? 0
        let dialog: IntentDialog = count == 0 ? "읽지 않은 메일이 없습니다." : "읽지 않은 메일이 \(count)통 있습니다."
        return .result(value: count, dialog: dialog)
    }
}

/// 받은 메일 가져오기
nonisolated struct GetNewMailIntent: AppIntent {
    static let title: LocalizedStringResource = "받은 메일 가져오기"
    static let description = IntentDescription("서버에서 새 메일을 가져옵니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentModel.ready()
        await model.refresh()
        await model.checkNewMail()
        let count = model.folders.first { $0.kind == "inbox" }?.unreadItemCount ?? 0
        return .result(dialog: "받은 메일을 가져왔습니다. 읽지 않은 메일 \(count)통.")
    }
}

/// VIP 메일 보기 (앱을 열어 VIP 상자를 고른다)
nonisolated struct ShowVIPMailIntent: AppIntent {
    static let title: LocalizedStringResource = "VIP 메일 보기"
    static let description = IntentDescription("FAKUKU Mail을 열어 VIP가 보낸 메일을 보여 줍니다.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentModel.ready()
        guard !model.mailboxes.vips.isEmpty else {
            return .result(dialog: "아직 VIP가 없습니다. 메일 머리글의 주소를 눌러 VIP에 추가하세요.")
        }
        model.selectedFolderID = VirtualMailbox.allVIPsID
        return .result(dialog: "VIP 메일을 열었습니다.")
    }
}

/// 읽지 않은 메일 보기 (받은 편지함 + 읽지 않음 필터)
nonisolated struct ShowUnreadMailIntent: AppIntent {
    static let title: LocalizedStringResource = "읽지 않은 메일 보기"
    static let description = IntentDescription("FAKUKU Mail을 열어 받은 편지함의 읽지 않은 메일만 보여 줍니다.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentModel.ready()
        model.selectedFolderID = model.folders.first { $0.kind == "inbox" }?.id ?? "inbox"
        var filter = MailFilter()
        filter.unread = true
        model.listFilter = filter
        return .result()
    }
}

/// 새 메일 쓰기 (받는 사람·제목은 선택)
/// 매개변수(@Parameter)가 있는 인텐트는 nonisolated struct로 둘 수 없다 (바뀌는 저장 속성).
/// 그래서 메인 액터 타입으로 두고 @preconcurrency로 프레임워크 프로토콜에 맞춘다. 정적 값은 nonisolated.
struct ComposeMailIntent: @preconcurrency AppIntent {
    nonisolated static let title: LocalizedStringResource = "새 메일 쓰기"
    nonisolated static let description = IntentDescription("FAKUKU Mail에서 새 메일 작성 창을 엽니다.")
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "받는 사람", description: "이름이나 이메일 주소")
    var recipient: String?

    @Parameter(title: "제목")
    var subject: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentModel.ready()
        var to = recipient ?? ""
        // 이름만 말했으면 주소록에서 찾는다.
        if !to.isEmpty, !to.contains("@"), let found = model.addressBook.suggestions(for: to).first {
            to = AddressParser.format([found])
        }
        model.pendingCompose = ComposeDraft(to: to, subject: subject ?? "")
        return .result()
    }
}

/// 메일 검색 (모든 폴더)
struct SearchMailIntent: @preconcurrency AppIntent {
    nonisolated static let title: LocalizedStringResource = "메일 검색"
    nonisolated static let description = IntentDescription("FAKUKU Mail에서 모든 폴더를 검색합니다.")
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "찾을 말")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentModel.ready()
        model.searchScope = .all
        model.searchText = text
        await model.loadMessages()
        return .result()
    }
}

// MARK: S-057 메일 읽어 주기, 지금 메일 다루기

/// 최근 메일 읽어 주기 (받은 편지함의 가장 최근 메일)
nonisolated struct ReadLatestMailIntent: AppIntent {
    static let title: LocalizedStringResource = "최근 메일 읽기"
    static let description = IntentDescription("받은 편지함의 가장 최근 메일의 보낸 사람, 제목, 앞부분을 읽어 줍니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentModel.ready()
        let inbox = model.folders.first { $0.kind == "inbox" }?.id ?? "inbox"
        guard let m = try await model.service.messages(folderID: inbox, search: nil).messages.first else {
            return .result(value: "", dialog: "받은 편지함에 메일이 없습니다.", view: MailSnippet(heading: L("받은 편지함에 메일이 없습니다."), rows: []))
        }
        let text = MailSpeech.latest(m)
        // 말로 읽는 것과 함께 카드로도 보인다: 카드가 있으면 Siri 창이 바로 닫히지 않는다.
        return .result(value: text, dialog: spoken(text), view: MailSnippet(heading: L("최근 메일"), rows: [.init(m)]))
    }
}

/// 읽지 않은 메일 읽어 주기 (받은 편지함, 다섯 통까지)
nonisolated struct ReadUnreadMailIntent: AppIntent {
    static let title: LocalizedStringResource = "읽지 않은 메일 읽기"
    static let description = IntentDescription("받은 편지함의 읽지 않은 메일을 다섯 통까지 보낸 사람과 제목으로 읽어 줍니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentModel.ready()
        await model.loadFolders()
        let inbox = model.folders.first { $0.kind == "inbox" }
        var unread = MailFilter()
        unread.unread = true
        let page = try await model.service.messages(folderID: inbox?.id ?? "inbox", search: nil, filter: unread, oldestFirst: false)
        let list = page.messages.filter(\.isUnread)
        let total = max(inbox?.unreadItemCount ?? 0, list.count)
        let text = MailSpeech.unreadSummary(list, total: total)
        let heading = total == 0 ? L("읽지 않은 메일이 없습니다.") : L("읽지 않은 메일 \(total)통")
        return .result(value: text, dialog: spoken(text),
                       view: MailSnippet(heading: heading, rows: list.prefix(5).map { MailSnippet.Row($0) }))
    }
}

/// Siri 창에 보이는 메일 카드 (보낸 사람, 제목, 앞부분). Siri가 그리므로 고정된 값만 쓴다.
struct MailSnippet: View {
    struct Row: Identifiable {
        let id: String
        let sender: String
        let subject: String
        let preview: String
        let unread: Bool

        init(_ m: MailMessage) {
            id = m.id
            sender = MailSpeech.sender(m)
            subject = m.title
            let text = (m.bodyPreview ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            preview = text.count > MailSpeech.previewLimit ? String(text.prefix(MailSpeech.previewLimit)) + "…" : text
            unread = m.isUnread
        }
    }

    let heading: String
    var symbol = "envelope"
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label(heading, systemImage: symbol)
                .font(.headline)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Circle()
                        .fill(r.unread ? Color.accentColor : Color.clear)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.sender)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(r.subject)
                            .lineLimit(1)
                        if !r.preview.isEmpty && rows.count == 1 {
                            Text(r.preview)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 앱이 만든 글을 Siri 대답으로 (번역 표에 없는 "%@" 키라 글이 그대로 나온다)
func spoken(_ text: String) -> IntentDialog { "\(text)" }

/// 지금 보고 있는 메일 (메인 창 본문). 없으면 Siri가 알려 준다.
enum IntentCurrentMail {
    @MainActor
    static func message(_ model: AppModel) -> MailMessage? {
        guard let m = model.detail, model.selectedMessageID != nil else { return nil }
        return m
    }

    static let missing: IntentDialog = "지금 열려 있는 메일이 없습니다. FAKUKU Mail에서 메일을 고른 뒤 다시 말해 주세요."
}

/// 이 메일에 깃발 달기
nonisolated struct FlagCurrentMailIntent: AppIntent {
    static let title: LocalizedStringResource = "이 메일에 깃발 달기"
    static let description = IntentDescription("FAKUKU Mail에서 지금 보고 있는 메일에 깃발을 답니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentModel.ready()
        guard let m = IntentCurrentMail.message(model) else {
            return .result(dialog: IntentCurrentMail.missing, view: MailSnippet(heading: L("열려 있는 메일이 없습니다"), rows: []))
        }
        if m.isFlagged {
            return .result(dialog: "이미 깃발이 달려 있습니다.", view: MailSnippet(heading: L("이미 깃발이 달려 있습니다."), rows: [.init(m)]))
        }
        guard await model.setFlag(id: m.id, flagged: true) else {
            return .result(dialog: "깃발을 달지 못했습니다.", view: MailSnippet(heading: L("깃발을 달지 못했습니다."), rows: [.init(m)]))
        }
        return .result(dialog: spoken(L("'\(m.title)'에 깃발을 달았습니다.")),
                       view: MailSnippet(heading: L("깃발을 달았습니다"), symbol: "flag.fill", rows: [.init(m)]))
    }
}

/// 이 메일에 답장 (작성 창을 연다)
nonisolated struct ReplyCurrentMailIntent: AppIntent {
    static let title: LocalizedStringResource = "이 메일에 답장"
    static let description = IntentDescription("FAKUKU Mail에서 지금 보고 있는 메일의 답장 창을 엽니다.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentModel.ready()
        guard IntentCurrentMail.message(model) != nil, let draft = model.draft(.reply) else {
            return .result(dialog: IntentCurrentMail.missing)
        }
        model.pendingCompose = draft
        return .result(dialog: "답장 창을 열었습니다.")
    }
}

/// 이 메일 보관 (단축어 앱에서 쓴다. Siri 문구는 앱당 10개까지라 넣지 않았다)
nonisolated struct ArchiveCurrentMailIntent: AppIntent {
    static let title: LocalizedStringResource = "이 메일 보관"
    static let description = IntentDescription("FAKUKU Mail에서 지금 보고 있는 메일을 보관 폴더로 옮깁니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentModel.ready()
        guard let m = IntentCurrentMail.message(model) else { return .result(dialog: IntentCurrentMail.missing) }
        model.selection = [m.id]
        await model.archiveSelected()
        return .result(dialog: spoken(L("'\(m.title)'을(를) 보관했습니다.")))
    }
}

/// Siri에 말로 부르는 문구. 문구마다 앱 이름이 들어가야 한다 (Info.plist의 INAlternativeAppNames로 "파쿠쿠 메일"도 된다).
nonisolated struct FakukuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: UnreadCountIntent(), phrases: [
            "\(.applicationName)에서 읽지 않은 메일 몇 통이야",
            "\(.applicationName) 읽지 않은 메일",
            "\(.applicationName) 안 읽은 메일 몇 개야",
        ], shortTitle: "읽지 않은 메일 수", systemImageName: "envelope.badge")
        AppShortcut(intent: GetNewMailIntent(), phrases: [
            "\(.applicationName) 새 메일 가져와",
            "\(.applicationName)에서 메일 확인해",
        ], shortTitle: "받은 메일 가져오기", systemImageName: "arrow.clockwise")
        AppShortcut(intent: ShowVIPMailIntent(), phrases: [
            "\(.applicationName) VIP 메일 보여 줘",
            "\(.applicationName)에서 VIP 메일",
        ], shortTitle: "VIP 메일", systemImageName: "star")
        AppShortcut(intent: ShowUnreadMailIntent(), phrases: [
            "\(.applicationName) 읽지 않은 메일 보여 줘",
        ], shortTitle: "읽지 않은 메일 보기", systemImageName: "envelope.open")
        AppShortcut(intent: ComposeMailIntent(), phrases: [
            "\(.applicationName)로 메일 써 줘",
            "\(.applicationName)에서 새 메일",
        ], shortTitle: "새 메일 쓰기", systemImageName: "square.and.pencil")
        AppShortcut(intent: SearchMailIntent(), phrases: [
            "\(.applicationName)에서 메일 검색",
        ], shortTitle: "메일 검색", systemImageName: "magnifyingglass")
        // S-057 (앱당 문구 묶음은 10개까지)
        AppShortcut(intent: ReadLatestMailIntent(), phrases: [
            "\(.applicationName) 최근 메일 읽어 줘",
            "\(.applicationName)에서 최근 메일 뭐야",
        ], shortTitle: "최근 메일 읽기", systemImageName: "envelope.badge")
        AppShortcut(intent: ReadUnreadMailIntent(), phrases: [
            "\(.applicationName) 읽지 않은 메일 읽어 줘",
            "\(.applicationName)에서 안 읽은 메일 읽어 줘",
        ], shortTitle: "읽지 않은 메일 읽기", systemImageName: "text.bubble")
        AppShortcut(intent: FlagCurrentMailIntent(), phrases: [
            "\(.applicationName) 이 메일에 깃발 달아 줘",
            "\(.applicationName)에서 깃발 달아 줘",
        ], shortTitle: "이 메일에 깃발", systemImageName: "flag")
        AppShortcut(intent: ReplyCurrentMailIntent(), phrases: [
            "\(.applicationName) 이 메일에 답장해 줘",
            "\(.applicationName)에서 답장 써 줘",
        ], shortTitle: "이 메일에 답장", systemImageName: "arrowshape.turn.up.left")
    }
}
