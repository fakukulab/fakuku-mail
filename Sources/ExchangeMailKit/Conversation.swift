import Foundation

/// 목록의 대화 한 줄 (S-025). 같은 폴더에서 같은 conversationId인 메일들.
public struct Conversation: Identifiable, Equatable, Sendable {
    /// 대화 id. conversationId가 없는 메일은 메일 id.
    public var id: String
    /// 최근 메일부터
    public var messages: [MailMessage]

    public var latest: MailMessage { messages[0] }
    public var count: Int { messages.count }
    public var isUnread: Bool { messages.contains(where: \.isUnread) }
    public var hasAttachments: Bool { messages.contains { $0.hasAttachments == true } }
    public var messageIDs: [String] { messages.map(\.id) }

    /// 보낸 사람 이름, 최근 사람부터 중복 없이. `me`는 "나"로 쓴다.
    public func participants(me: String?) -> [String] {
        let myKey = me?.lowercased()
        var names: [String] = []
        for m in messages {
            let address = m.from?.emailAddress.address?.lowercased()
            let name = address != nil && address == myKey ? "나" : (m.from?.emailAddress.display ?? "")
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }
}

public enum Conversations {
    /// 목록을 대화로 묶는다. 대화 순서는 최근 메일 순, 대화 안도 최근 순.
    public static func group(_ messages: [MailMessage]) -> [Conversation] {
        var order: [String] = []
        var buckets: [String: [MailMessage]] = [:]
        for m in messages {
            let key = (m.conversationId?.isEmpty == false ? m.conversationId : nil) ?? "message:\(m.id)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(m)
        }
        func date(_ m: MailMessage) -> Date { m.receivedDateTime ?? .distantPast }
        return order
            .map { key in Conversation(id: key, messages: buckets[key, default: []].sorted { date($0) > date($1) }) }
            .sorted { date($0.latest) > date($1.latest) }
    }

    /// 대화 전체를 가져오는 Graph `$filter` 값. 작은따옴표는 OData 규칙대로 두 번 쓴다.
    public static func filter(conversationID: String) -> String {
        "conversationId eq '\(conversationID.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// 대화 보기 순서: 오래된 메일부터.
    public static func chronological(_ messages: [MailMessage]) -> [MailMessage] {
        messages.sorted { ($0.receivedDateTime ?? .distantPast) < ($1.receivedDateTime ?? .distantPast) }
    }
}

/// URL 쿼리에서 `+`는 서버가 공백으로 읽을 수 있다. base64 id(대화 id 등)가 깨지지 않게 %2B로 바꾼다.
public enum QueryEncoding {
    public static func fixPlus(_ percentEncodedQuery: String?) -> String? {
        percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
}
