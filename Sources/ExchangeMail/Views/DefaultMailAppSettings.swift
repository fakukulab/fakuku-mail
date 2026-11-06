import AppKit
import ExchangeMailKit
import SwiftUI
import UniformTypeIdentifiers

/// 기본 이메일 앱 (1.0.1): 웹 브라우저·다른 앱의 메일 링크(mailto:)와 Finder의 .eml 파일을 열 앱.
/// 맥 Mail의 설정 > 일반 > 기본 이메일 앱과 같이 macOS의 값을 바꾼다 (이 앱에 저장하지 않는다).
enum DefaultMailApp {
    struct Handler: Identifiable, Hashable {
        let url: URL
        let name: String
        var id: URL { url }
    }

    private static let mailtoURL = URL(string: "mailto:someone@example.com")!  // l10n: data
    /// 기본 앱을 같이 바꾸는 메일 파일 종류
    static let fileTypes: [UTType] = [UTType("com.apple.mail.email"), UTType("com.apple.mail.emlx")].compactMap { $0 }  // l10n: data

    /// 지금 mailto: 링크를 여는 앱
    static func current() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: mailtoURL)?.standardizedFileURL
    }

    /// 고를 수 있는 앱: mailto: 링크를 열 수 있는 앱과 이 앱 (같은 앱이 여러 곳에 있으면 지금 쓰는 것 하나). 이름 순.
    static func handlers() -> [Handler] {
        let now = current()
        var urls = NSWorkspace.shared.urlsForApplications(toOpen: mailtoURL).map(\.standardizedFileURL)
        urls.append(Bundle.main.bundleURL.standardizedFileURL)
        if let now { urls.insert(now, at: 0) }
        var seen = Set<String>()
        var list: [Handler] = []
        for url in urls {
            let key = Bundle(url: url)?.bundleIdentifier ?? url.path
            guard seen.insert(key).inserted else { continue }
            // 이 앱은 지금 실행 중인 것으로 (개발 빌드와 배포본이 같이 있어도 하나)
            let chosen = key == Bundle.main.bundleIdentifier && url != now ? Bundle.main.bundleURL.standardizedFileURL : url
            let name = FileManager.default.displayName(atPath: chosen.path)
            list.append(Handler(url: chosen, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name))
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 앱 아이콘 (메뉴에 맞는 16pt)
    static func icon(_ url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// 기본 이메일 앱을 바꾼다. macOS가 바꿀지 묻는 창을 띄울 수 있다 (거절하면 그대로).
    /// 그 앱이 .eml 파일도 열 수 있으면 .eml도 그 앱으로.
    static func set(_ app: URL) async {
        // 테스트·스냅숏·데모는 이 Mac의 설정을 바꾸지 않는다.
        guard !Store.isOverridden else { return }
        let changed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "mailto") { error in  // l10n: data
                done.resume(returning: error == nil)
            }
        }
        guard changed else { return }
        for type in fileTypes where NSWorkspace.shared.urlsForApplications(toOpen: type)
            .map(\.standardizedFileURL).contains(app.standardizedFileURL) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { _ in done.resume() }
            }
        }
    }
}

/// 설정 > 일반 > 기본 이메일 앱:
struct DefaultMailAppSettings: View {
    @State private var handlers: [DefaultMailApp.Handler] = []
    @State private var current: URL?

    var body: some View {
        LabeledContent(L("기본 이메일 앱:")) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Picker(L("기본 이메일 앱"), selection: Binding(get: { current }, set: { choose($0) })) {
                        if current == nil { Text(L("없음")).tag(URL?.none) }
                        ForEach(handlers) { app in
                            Label { Text(app.name) } icon: { Image(nsImage: DefaultMailApp.icon(app.url)) }
                                .tag(URL?.some(app.url))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if !isThisApp {
                        Button(L("FAKUKU Mail로 지정")) { choose(Bundle.main.bundleURL.standardizedFileURL) }
                    }
                }
                SettingsNote(isThisApp
                    ? L("웹 브라우저나 다른 앱의 메일 링크를 누르면 FAKUKU Mail의 새 메시지 창이 열리고, ")
                        + L("Finder에서 .eml 파일을 열면 FAKUKU Mail에서 읽고 답장·전달할 수 있습니다.")
                    : L("메일 링크(mailto:)와 .eml 파일을 열 앱입니다. macOS가 바꿀지 물어볼 수 있습니다."))
            }
        }
        .onAppear(perform: reload)
    }

    private var isThisApp: Bool {
        guard let current else { return false }
        return Bundle(url: current)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func choose(_ app: URL?) {
        guard let app, app != current else { return }
        current = app
        Task {
            await DefaultMailApp.set(app)
            reload()
        }
    }

    private func reload() {
        handlers = DefaultMailApp.handlers()
        current = DefaultMailApp.current()
        // 목록에 없는 경로(같은 앱의 다른 사본)면 목록의 그 앱으로 맞춘다.
        if let c = current, !handlers.contains(where: { $0.url == c }),
           let id = Bundle(url: c)?.bundleIdentifier,
           let same = handlers.first(where: { Bundle(url: $0.url)?.bundleIdentifier == id }) {
            current = same.url
        }
    }
}
