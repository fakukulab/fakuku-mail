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

    /// 모든 계정의 받은 편지함을 보고 새 메일을 알린다 (M23: 계정마다 기준을 따로 둔다).
    /// 앱이 뒤에 있어도 2분마다 불린다. 오류는 조용히 넘긴다.
    func checkNewMail() async {
        guard isSignedIn else { return }
        var anyFresh = false
        for account in accounts.accounts {
            let key = account.email.lowercased()
            var tracker = loadTracker(key)
            let inboxID = accountFolders[account.id]?.first { $0.kind == "inbox" }?.id ?? "inbox"
            guard let page = try? await account.service.messages(folderID: inboxID, search: nil) else { continue }
            router.noteOwner(page.messages, account: account.id)
            let fresh = tracker.take(page.messages)
            trackers[key] = tracker
            saveTracker(tracker, key: key)
            if notifyNewMail && notificationPermission == .allowed {
                // 알림을 끈 대화의 메일은 알리지 않는다 (메시지 > 알림 비활성화).
                let wanted = fresh.filter { !mutedConversations.contains($0.conversationId ?? "") }
                for n in MailNotification.make(for: wanted) { notifier.post(n, sound: notifySound) }
            }
            if !fresh.isEmpty { anyFresh = true }
        }
        if anyFresh {
            await loadFolders()
            let showingInbox = selectedFolder?.kind == "inbox" || selectedVirtual == .allInboxes
            if showingInbox && searchText.isEmpty { await loadMessages(keepSelection: true) }
        }
    }

    /// Dock 배지 = 모든 계정의 받은 편지함 읽지 않은 수의 합. 설정에서 끄면 지운다.
    func updateBadge() {
        let counts = accounts.accounts.compactMap { accountFolders[$0.id]?.first { $0.kind == "inbox" }?.unreadItemCount }
        let unread: Int? = counts.isEmpty ? folders.first { $0.kind == "inbox" }?.unreadItemCount : counts.reduce(0, +)
        notifier.setBadge(showBadge && isSignedIn ? DockBadge.label(unread: unread) : nil)
    }

    /// 알림을 눌렀을 때: 받은 편지함에서 그 메일을 연다. 요약 알림(id 없음)은 받은 편지함만 연다.
    func openFromNotification(_ id: String?) async {
        guard isSignedIn else { return }
        // 그 메일의 계정 받은 편지함을 연다 (M23)
        let owner = id.flatMap { router.accountID(forMessage: $0) } ?? accounts.active?.id
        let inboxID = owner.flatMap { accountFolders[$0]?.first { $0.kind == "inbox" }?.id }
            ?? folders.first { $0.kind == "inbox" }?.id ?? "inbox"
        pendingOpenID = id
        if selectedFolderID != inboxID {
            selectedFolderID = inboxID   // didSet이 목록을 불러오고 pendingOpenID를 고른다
        } else {
            searchText = ""
            await loadMessages(keepSelection: true)
        }
    }

    /// 새 메일 기준은 계정마다 UserDefaults에 둔다. 테스트 실행(APP_STORE)은 메모리에만.
    private func loadTracker(_ key: String) -> NewMailTracker {
        if let t = trackers[key] { return t }
        guard !Store.isOverridden, let data = UserDefaults.standard.data(forKey: "newMail.tracker.\(key)"),
              let saved = try? JSONDecoder().decode(NewMailTracker.self, from: data) else { return NewMailTracker() }
        trackers[key] = saved
        return saved
    }

    private func saveTracker(_ tracker: NewMailTracker, key: String) {
        guard !Store.isOverridden, let data = try? JSONEncoder().encode(tracker) else { return }
        UserDefaults.standard.set(data, forKey: "newMail.tracker.\(key)")
    }
}
