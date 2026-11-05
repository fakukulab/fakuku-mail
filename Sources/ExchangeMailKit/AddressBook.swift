import Foundation

/// 받는 사람 자동완성용 주소록 (S-018). 받은·보낸 메일에서 본 주소를 모은다.
/// 별도 권한(People.Read, Contacts.Read)이 없어도 되도록 서버 주소록은 쓰지 않는다.
public struct AddressBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var address: MailAddress
        /// 내가 이 주소로 보낸 횟수. 많이 보낸 사람이 위로 온다.
        public var sentCount: Int
        /// 받은 메일에서 본 횟수
        public var seenCount: Int
        public var lastUsed: Date

        var score: Double { Double(sentCount) * 5 + Double(seenCount) }
    }

    /// 키: 소문자 주소
    public private(set) var entries: [String: Entry] = [:]
    /// 너무 커지지 않게 이 수를 넘으면 오래되고 덜 쓴 것부터 버린다.
    public var limit = 2000

    public init() {}

    /// 메일에서 본 주소. 이름이 없던 항목은 이름을 채운다. `me`(내 주소)는 넣지 않는다.
    public mutating func noteSeen(_ addresses: [MailAddress], me: String?, at date: Date = Date()) {
        note(addresses, me: me, date: date, sent: false)
    }

    /// 내가 보낸 받는 사람.
    /// 이전 수신자 목록에서 지운다 (자동완성에 다시 나오지 않게)
    public mutating func remove(_ address: String) {
        entries.removeValue(forKey: address.lowercased())
    }

    public mutating func noteSent(_ addresses: [MailAddress], me: String?, at date: Date = Date()) {
        note(addresses, me: me, date: date, sent: true)
    }

    private mutating func note(_ addresses: [MailAddress], me: String?, date: Date, sent: Bool) {
        let myKey = me?.lowercased()
        for a in addresses where AddressParser.isValid(a.address) {
            let key = a.address.lowercased()
            if key == myKey { continue }
            var e = entries[key] ?? Entry(address: a, sentCount: 0, seenCount: 0, lastUsed: date)
            if let name = a.name, !name.isEmpty, name != a.address { e.address.name = name }
            if sent { e.sentCount += 1 } else { e.seenCount += 1 }
            e.lastUsed = max(e.lastUsed, date)
            entries[key] = e
        }
        trim()
    }

    private mutating func trim() {
        guard entries.count > limit else { return }
        let keep = entries.sorted { ($0.value.score, $0.value.lastUsed) > ($1.value.score, $1.value.lastUsed) }.prefix(limit)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// 입력 칸의 마지막 항목(쉼표·세미콜론 뒤)을 이름이나 주소로 찾는다.
    /// 이미 칸에 들어 있는 주소는 빼고, 많이 보낸 순 → 최근 순으로 돌려준다.
    public func suggestions(for fieldText: String, limit: Int = 8) -> [MailAddress] {
        let query = Self.lastToken(fieldText).lowercased()
        guard !query.isEmpty else { return [] }
        let already = Set(AddressParser.parse(Self.headText(fieldText)).valid.map { $0.address.lowercased() })
        return entries.values
            .filter { !already.contains($0.address.address.lowercased()) && Self.matches($0.address, query) }
            .sorted { a, b in
                let pa = Self.prefixRank(a.address, query), pb = Self.prefixRank(b.address, query)
                if pa != pb { return pa < pb }
                if a.score != b.score { return a.score > b.score }
                return a.lastUsed > b.lastUsed
            }
            .prefix(limit)
            .map(\.address)
    }

    /// 고른 주소로 마지막 항목을 바꾸고 다음 입력을 위해 ", "를 붙인다.
    public static func complete(_ fieldText: String, with address: MailAddress) -> String {
        let head = headText(fieldText).trimmingCharacters(in: .whitespaces)
        let separator = head.isEmpty ? "" : (head.hasSuffix(",") || head.hasSuffix(";") ? " " : ", ")
        return head + separator + address.editable + ", "
    }

    // MARK: helpers

    /// 마지막 구분자(쉼표, 세미콜론) 위치. 꺾쇠나 따옴표 안의 것은 무시한다.
    static func lastSeparator(_ text: String) -> String.Index? {
        var inQuotes = false, inAngle = false
        var last: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\"" { inQuotes.toggle() }
            else if ch == "<" && !inQuotes { inAngle = true }
            else if ch == ">" && !inQuotes { inAngle = false }
            else if (ch == "," || ch == ";") && !inQuotes && !inAngle { last = i }
            i = text.index(after: i)
        }
        return last
    }

    /// 받는 사람 칸을 끝난 항목(쉼표·세미콜론 앞)과 지금 쓰는 글자로 나눈다 (작성 창의 주소 토큰)
    public static func pieces(_ text: String) -> (tokens: [String], pending: String) {
        guard let sep = lastSeparator(text) else { return ([], text.trimmingCharacters(in: .whitespaces)) }
        return (AddressParser.split(String(text[..<sep])),
                String(text[text.index(after: sep)...]).trimmingCharacters(in: .whitespaces))
    }

    /// `pieces`를 다시 칸 글자로
    public static func join(tokens: [String], pending: String) -> String {
        tokens.isEmpty ? pending : tokens.joined(separator: ", ") + ", " + pending
    }

    static func lastToken(_ text: String) -> String {
        let start = lastSeparator(text).map { text.index(after: $0) } ?? text.startIndex
        return text[start...].trimmingCharacters(in: .whitespaces)
    }

    /// 마지막 항목 앞부분 (구분자 포함).
    static func headText(_ text: String) -> String {
        guard let sep = lastSeparator(text) else { return "" }
        return String(text[...sep])
    }

    static func matches(_ a: MailAddress, _ q: String) -> Bool {
        a.address.lowercased().contains(q) || (a.name?.lowercased().contains(q) ?? false)
    }

    /// 0: 이름이나 주소가 그대로 시작, 1: 단어 시작, 2: 중간 포함
    static func prefixRank(_ a: MailAddress, _ q: String) -> Int {
        let name = a.name?.lowercased() ?? ""
        let address = a.address.lowercased()
        if name.hasPrefix(q) || address.hasPrefix(q) { return 0 }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }) + address.split(whereSeparator: { "._-@".contains($0) })
        if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
        return 2
    }
}
