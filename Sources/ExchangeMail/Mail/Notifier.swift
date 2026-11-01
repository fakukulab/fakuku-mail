import AppKit
import ExchangeMailKit
import Foundation
import UserNotifications

enum NotifyPermission: Equatable {
    case allowed, denied, notAsked
}

/// 새 메일 알림과 Dock 배지 (S-024). 실제는 SystemNotifier, 데모·셀프 테스트는 RecordingNotifier.
protocol MailNotifier: AnyObject {
    func permission() async -> NotifyPermission
    /// 아직 묻지 않았으면 묻는다.
    func requestPermission() async -> NotifyPermission
    func post(_ notification: MailNotification, sound: Bool)
    func setBadge(_ label: String?)
}

/// 알림을 누르면 열 메일을 앱에 넘긴다. ContentView가 `open`을 채운다.
final class NotificationRouter {
    static let shared = NotificationRouter()
    var open: ((String?) -> Void)?
}

/// macOS 알림 센터. 알림 센터 대리자이기도 하다 (AppDelegate가 시작할 때 연결).
final class SystemNotifier: NSObject, MailNotifier, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()
    private var center: UNUserNotificationCenter { .current() }

    func permission() async -> NotifyPermission {
        let status: UNAuthorizationStatus = await withCheckedContinuation { continuation in
            center.getNotificationSettings { @Sendable settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        switch status {
        case .authorized, .provisional: return .allowed
        case .denied: return .denied
        default: return .notAsked
        }
    }

    func requestPermission() async -> NotifyPermission {
        let current = await permission()
        guard current == .notAsked else { return current }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        return granted ? .allowed : .denied
    }

    func post(_ n: MailNotification, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.subtitle = n.subtitle
        content.body = n.body
        content.threadIdentifier = n.threadID
        if let id = n.messageID { content.userInfo = ["messageID": id] }
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil), withCompletionHandler: nil)
    }

    func setBadge(_ label: String?) {
        NSApp.dockTile.badgeLabel = label
    }

    // MARK: UNUserNotificationCenterDelegate
    // nonisolated + async: 알림 센터가 어느 스레드에서 불러도 메인 액터 가정으로 멈추지 않게.

    /// 앱이 앞에 있으면 배너 없이 알림 센터에만 남긴다 (목록에 바로 보이므로).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let active = await MainActor.run { NSApp.isActive }
        return active ? [.list] : [.banner, .list, .sound]
    }

    /// 알림을 누르면 앱을 앞으로 가져오고 그 메일을 연다.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["messageID"] as? String
        await MainActor.run {
            NSApp.activate()
            NotificationRouter.shared.open?(id)
        }
    }
}

/// 데모·셀프 테스트용: 알림을 띄우지 않고 기록만 한다.
final class RecordingNotifier: MailNotifier {
    private(set) var posted: [MailNotification] = []
    private(set) var badge: String?

    func permission() async -> NotifyPermission { .allowed }
    func requestPermission() async -> NotifyPermission { .allowed }
    func post(_ notification: MailNotification, sound: Bool) { posted.append(notification) }
    func setBadge(_ label: String?) { badge = label }
}
