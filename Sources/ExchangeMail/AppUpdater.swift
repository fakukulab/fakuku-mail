import AppKit
import Combine
import Sparkle

/// 자동 업데이트 (1.0.2, Sparkle).
/// 앱을 켤 때 한 번 소개 사이트의 appcast.xml(Info.plist `SUFeedURL`)을 본다 (1.0.9). 켜 둔 동안에는 다시 보지 않는다.
/// 새 버전이 있으면 Sparkle 창에 "업데이트 설치"가 보이고, 누르면 GitHub 릴리스의 DMG를 받아
/// 서명(EdDSA, `SUPublicEDKey`)을 확인한 뒤 바꾸고 다시 켠다. 몰래 받아 두었다 끌 때 바꾸는 자동 설치는 쓰지 않는다
/// (Info.plist `SUAllowsAutomaticUpdates` false: 켜 둔 메일 앱은 끌 일이 드물어 설치되지 않는 것처럼 보였다).
/// "나중에"를 누르면 다음에 앱을 켤 때 다시 묻는다.
/// 메뉴: FAKUKU Mail > 업데이트 확인…  설정: 일반 > 업데이트.
/// 테스트·스냅숏·데모(APP_STORE)에서는 켜지 않는다: 서버에 묻지도, 앱을 바꾸지도 않는다.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?
    /// 켜 둔 동안 다시 확인하지 않게 하는 Sparkle 대리인 (controller는 약하게 잡으므로 여기서 붙든다)
    private let gate = LaunchCheckGate()
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
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: gate, userDriverDelegate: nil)
        controller = c
        // 앱을 켤 때 한 번 (Sparkle 권장: 시작한 바로 뒤, 자동 확인이 켜져 있을 때만)
        if c.updater.automaticallyChecksForUpdates { c.updater.checkForUpdatesInBackground() }
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

    /// 설정 > 일반 > 업데이트: 앱을 켤 때 새 버전 확인
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

    /// 마지막으로 확인한 때 (아직 없으면 nil)
    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }
}

/// 켜 둔 동안 저절로 하는 확인은 앱을 켠 뒤 첫 번째만 허락한다. 사람이 누른 "업데이트 확인…"은 언제나 된다.
final class LaunchCheckGate: NSObject, SPUUpdaterDelegate {
    private var launchCheckDone = false

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        if launchCheckDone {
            throw NSError(domain: "FAKUKUMail.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Checked at launch already"]) // l10n: data
        }
        launchCheckDone = true
    }
}
