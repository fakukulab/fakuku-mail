import Foundation

/// 새 메일 판정 (S-024). 받은 편지함 맨 위 메일 목록을 볼 때마다 부른다.
public struct NewMailTracker: Codable, Equatable, Sendable {
    /// 이 시각보다 늦게 받은 메일만 새 메일이다. nil이면 아직 한 번도 확인하지 않았다.
    public private(set) var watermark: Date?
    /// 이미 알린 메일 id (같은 시각에 온 메일을 두 번 알리지 않게). 최근 것만 둔다.
    public private(set) var notified: [String] = []

    public init() {}

    /// 새로 알릴 메일을 돌려주고 기준을 옮긴다. 처음에는 기준만 정하고 아무것도 돌려주지 않는다.
    public mutating func take(_ inbox: [MailMessage], now: Date = Date()) -> [MailMessage] {
        let newest = inbox.compactMap(\.receivedDateTime).max()
        guard let mark = watermark else {
            // 처음: 지금 있는 메일은 모두 알린 것으로 친다.
            watermark = newest ?? now
            notified = Array(inbox.map(\.id).prefix(200))
            return []
        }
        let known = Set(notified)
        let fresh = inbox
            .filter { m in
                guard let date = m.receivedDateTime else { return false }
                return date >= mark && m.isUnread && !known.contains(m.id)
            }
            .sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
        if let newest, newest > mark { watermark = newest }
        notified = Array((fresh.map(\.id) + notified).prefix(200))
        return fresh
    }
}

/// 알림 한 건의 글자.
public struct MailNotification: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var body: String
    /// 알림 센터에서 같은 대화끼리 묶는 키
    public var threadID: String
    /// 누르면 열 메일 (요약 알림은 nil)
    public var messageID: String?

    /// 3통까지는 한 통씩, 그보다 많으면 요약 하나.
    public static func make(for messages: [MailMessage], maxSingles: Int = 3) -> [MailNotification] {
        guard !messages.isEmpty else { return [] }
        if messages.count > maxSingles {
            var senders: [String] = []
            for m in messages {
                let name = m.from?.emailAddress.display ?? ""
                if !name.isEmpty && !senders.contains(name) { senders.append(name) }
            }
            let names = senders.prefix(3).joined(separator: ", ") + (senders.count > 3 ? " 외" : "")
            return [MailNotification(id: "summary-\(messages[0].id)", title: "새 메일 \(messages.count)통",
                                     subtitle: names, body: messages.prefix(3).map(\.title).joined(separator: "\n"),
                                     threadID: "inbox", messageID: nil)]
        }
        return messages.map { m in
            MailNotification(id: m.id,
                             title: m.from?.emailAddress.display ?? "새 메일",
                             subtitle: m.title,
                             body: String((m.bodyPreview ?? "").prefix(180)),
                             threadID: m.conversationId ?? m.id,
                             messageID: m.id)
        }
    }
}

public enum DockBadge {
    /// Dock 배지 글자. 0이면 nil(배지 없음), 999 넘으면 "999+".
    public static func label(unread: Int?) -> String? {
        guard let n = unread, n > 0 else { return nil }
        return n > 999 ? "999+" : "\(n)"
    }
}
