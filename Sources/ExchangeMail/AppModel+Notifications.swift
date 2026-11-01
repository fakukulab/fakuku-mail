import AppKit
import ExchangeMailKit
import Foundation

/// 새 메일 알림과 Dock 배지 (S-024)
extension AppModel {
    // MARK: 새 메일 알림 (S-024)

    static func setting(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    var notifyNewMail: Bool { Self.setting("notify.newMail") }
    var notifySound: Bool { Self.setting("notify.sound") }
    var showBadge: Bool { Self.setting("notify.badge") }

    /// 로그인한 뒤 한 번: 알림을 켜 두었으면 권한을 묻는다(처음일 때만).
    func prepareNotifications() async {
        guard isSignedIn else { return }
        if notifyNewMail {
            notificationPermission = await notifier.requestPermission()
        } else {
            notificationPermission = await notifier.permission()
        }
    }

    func refreshNotificationPermission() async {
        notificationPermission = await notifier.permission()
    }

    /// 받은 편지함을 보고 새 메일을 알린다. 앱이 뒤에 있어도 2분마다 불린다. 오류는 조용히 넘긴다.
    func checkNewMail() async {
        guard isSignedIn else { return }
        loadTracker()
        guard let page = try? await service.messages(folderID: "inbox", search: nil) else { return }
        let fresh = tracker.take(page.messages)
        saveTracker()
        if notifyNewMail && notificationPermission == .allowed {
            for n in MailNotification.make(for: fresh) { notifier.post(n, sound: notifySound) }
        }
        if !fresh.isEmpty {
            await loadFolders()
            if selectedFolder?.kind == "inbox" && searchText.isEmpty { await loadMessages(keepSelection: true) }
        }
    }

    /// Dock 배지 = 받은 편지함의 읽지 않은 수. 설정에서 끄면 지운다.
    func updateBadge() {
        let unread = folders.first { $0.kind == "inbox" }?.unreadItemCount
        notifier.setBadge(showBadge && isSignedIn ? DockBadge.label(unread: unread) : nil)
    }

    /// 알림을 눌렀을 때: 받은 편지함에서 그 메일을 연다. 요약 알림(id 없음)은 받은 편지함만 연다.
    func openFromNotification(_ id: String?) async {
        guard isSignedIn else { return }
        let inboxID = folders.first { $0.kind == "inbox" }?.id ?? "inbox"
        pendingOpenID = id
        if selectedFolderID != inboxID {
            selectedFolderID = inboxID   // didSet이 목록을 불러오고 pendingOpenID를 고른다
        } else {
            searchText = ""
            await loadMessages(keepSelection: true)
        }
    }

    /// 새 메일 기준은 계정마다 UserDefaults에 둔다. 테스트 실행(APP_STORE)은 메모리에만.
    private var trackerKey: String { "newMail.tracker.\((auth.email ?? "").lowercased())" }

    private func loadTracker() {
        guard !trackerLoaded else { return }
        trackerLoaded = true
        guard !Store.isOverridden, let data = UserDefaults.standard.data(forKey: trackerKey),
              let saved = try? JSONDecoder().decode(NewMailTracker.self, from: data) else { return }
        tracker = saved
    }

    private func saveTracker() {
        guard !Store.isOverridden, let data = try? JSONEncoder().encode(tracker) else { return }
        UserDefaults.standard.set(data, forKey: trackerKey)
    }
}
