import AppKit
import Combine
import Sparkle

/// 자동 업데이트 (1.0.2, Sparkle).
/// 하루에 한 번 소개 사이트의 appcast.xml(Info.plist `SUFeedURL`)을 보고, 새 버전이 있으면 GitHub 릴리스의 DMG를 받아
/// 서명(EdDSA, `SUPublicEDKey`)을 확인한 뒤 바꾼다. 받기·설치를 자동으로 하면 앱을 끌 때 설치된다.
/// 메뉴: FAKUKU Mail > 업데이트 확인…  설정: 일반 > 업데이트.
/// 테스트·스냅숏·데모(APP_STORE)에서는 켜지 않는다: 서버에 묻지도, 앱을 바꾸지도 않는다.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var watchers: Set<AnyCancellable> = []

    /// 지금 "업데이트 확인…"을 누를 수 있는가 (이미 확인·설치 중이면 false)
    private(set) var canCheck = false

    /// 이 앱이 업데이트를 받을 수 있는가 (테스트 실행, 업데이트 주소나 공개 키가 빠진 개발 빌드는 false)
    var isAvailable: Bool { controller != nil }

    private init() {
        guard !Store.isOverridden, Self.isConfigured(Bundle.main) else {
            controller = nil
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheck = value }
            .store(in: &watchers)
    }

    /// 앱 정보에 업데이트 주소(https)와 공개 키가 있는가
    static func isConfigured(_ bundle: Bundle) -> Bool {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    /// FAKUKU Mail > 업데이트 확인…: 결과를 창으로 보인다 (최신이면 "최신 버전입니다").
    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    /// 설정 > 일반 > 업데이트: 하루에 한 번 자동으로 확인
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// 설정 > 일반 > 업데이트: 새 버전을 자동으로 받아 두고, 앱을 끌 때 설치
    var installsAutomatically: Bool {
        get {
            access(keyPath: \.installsAutomatically)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.installsAutomatically) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// 마지막으로 확인한 때 (아직 없으면 nil)
    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }
}
