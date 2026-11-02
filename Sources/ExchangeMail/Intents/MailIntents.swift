import AppIntents
import ExchangeMailKit
import Foundation

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
nonisolated struct ComposeMailIntent: AppIntent {
    static let title: LocalizedStringResource = "새 메일 쓰기"
    static let description = IntentDescription("FAKUKU Mail에서 새 메일 작성 창을 엽니다.")
    static let openAppWhenRun = true

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
nonisolated struct SearchMailIntent: AppIntent {
    static let title: LocalizedStringResource = "메일 검색"
    static let description = IntentDescription("FAKUKU Mail에서 모든 폴더를 검색합니다.")
    static let openAppWhenRun = true

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
    }
}
