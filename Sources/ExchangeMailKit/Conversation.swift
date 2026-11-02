import Foundation

/// 목록의 대화 한 줄 (S-025). 같은 폴더에서 같은 conversationId인 메일들.
public struct Conversation: Identifiable, Equatable, Sendable {
    public init(id: String, messages: [MailMessage], related: [MailMessage] = []) {
        self.id = id
        self.messages = messages
        self.related = related
    }

    /// 대화 id. conversationId가 없는 메일은 메일 id.
    public var id: String
    /// 최근 메일부터 (이 폴더의 메일만. 고르기·옮기기는 이 메일들에 한다)
    public var messages: [MailMessage]
    /// 다른 폴더에 있는 같은 대화의 메일 (보낸 편지함의 내 답장 등). 줄의 메일 수와 참여자에만 쓴다.
    public var related: [MailMessage] = []

    public var latest: MailMessage { messages[0] }
    /// 대화의 메일 수: 이 폴더 + 관련 메일 (맥 Mail처럼 내 답장까지 센다)
    public var count: Int { messages.count + related.count }
    public var isUnread: Bool { messages.contains(where: \.isUnread) }
    public var hasAttachments: Bool { messages.contains { $0.hasAttachments == true } }
    public var messageIDs: [String] { messages.map(\.id) }

    /// 보낸 사람 이름, 최근 사람부터 중복 없이. `me`는 "나"로 쓴다.
    public func participants(me: String?) -> [String] {
        let myKey = me?.lowercased()
        var names: [String] = []
        for m in (messages + related).sorted(by: { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }) {
            let address = m.from?.emailAddress.address?.lowercased()
            let name = address != nil && address == myKey ? L("나") : (m.from?.emailAddress.display ?? "")
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }
}

public enum Conversations {
    static let replyPrefixes = ["re:", "fw:", "fwd:", "회신:", "전달:", "답장:", "aw:", "sv:", "wg:", "tr:", "rv:"]  // l10n: data

    /// 대화 비교용 제목: 앞의 RE:, FW:, 회신: 등을 모두 떼고, 공백을 하나로, 소문자로.
    public static func normalizedSubject(_ subject: String?) -> (base: String, wasReply: Bool) {
        var s = (subject ?? "").trimmingCharacters(in: .whitespaces)
        var reply = false
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for p in replyPrefixes where lower.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                reply = true
                changed = true
                break
            }
            // "RE[2]:" 같은 꼴
            if !changed, let r = s.range(of: #"^(re|fw|fwd)\[\d+\]:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r)
                reply = true
                changed = true
            }
        }
        let base = s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (base, reply)
    }

    /// 목록을 대화로 묶는다. 대화 순서는 최근 메일 순, 대화 안도 최근 순.
    /// 1) 같은 conversationId끼리. 2) Exchange가 대화를 나눠 버린 경우(바깥 메일 앱의 답장 등)를 위해,
    ///    제목이 같고 한쪽이 답장·전달(RE:, 회신: …)이면 하나로 합친다 (답장 아닌 같은 제목 메일끼리는 합치지 않는다).
    /// `related`(다른 폴더의 메일)는 같은 대화에 붙여 수만 센다.
    public static func group(_ messages: [MailMessage], related: [MailMessage] = []) -> [Conversation] {
        func key(_ m: MailMessage) -> String { (m.conversationId?.isEmpty == false ? m.conversationId : nil) ?? "message:\(m.id)" }
        var order: [String] = []
        var buckets: [String: [MailMessage]] = [:]
        for m in messages {
            let k = key(m)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(m)
        }
        // 제목으로 합치기
        var bySubject: [String: String] = [:]   // 정규화 제목 → 대표 key
        var replyish: [String: Bool] = [:]      // key → 그 대화에 답장·전달이 있는지
        var merged: [String: String] = [:]      // 합쳐진 key → 대표 key
        for k in order {
            let subjects = buckets[k, default: []].map { normalizedSubject($0.subject) }
            let isReply = subjects.contains { $0.wasReply }
            replyish[k] = isReply
            guard let base = subjects.first?.base, base.count >= 2 else { continue }
            if let target = bySubject[base], isReply || replyish[target] == true {
                buckets[target, default: []] += buckets[k, default: []]
                replyish[target] = true
                merged[k] = target
            } else if bySubject[base] == nil {
                bySubject[base] = k
            }
        }
        order.removeAll { merged[$0] != nil }
        func root(_ k: String) -> String { merged[k] ?? k }

        // 다른 폴더의 같은 대화 메일
        let own = Set(messages.map(\.id))
        var extra: [String: [MailMessage]] = [:]
        for r in related where !own.contains(r.id) {
            let k = root(key(r))
            if buckets[k] != nil {
                extra[k, default: []].append(r)
            } else {
                let n = normalizedSubject(r.subject)
                if let target = bySubject[n.base].map(root), n.wasReply || replyish[target] == true {
                    extra[target, default: []].append(r)
                }
            }
        }

        func date(_ m: MailMessage) -> Date { m.receivedDateTime ?? .distantPast }
        return order
            .map { k in
                Conversation(id: k, messages: buckets[k, default: []].sorted { date($0) > date($1) },
                             related: extra[k, default: []].sorted { date($0) > date($1) })
            }
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
