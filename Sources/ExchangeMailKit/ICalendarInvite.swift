import Foundation

// iCloud·Gmail 회의 초대 (1.0.3): 메일에 붙은 일정 파일(text/calendar, .ics)을 읽고, 주최자에게 답장(METHOD:REPLY)을 만든다.
// 규칙: RFC 5545 (iCalendar), RFC 5546 (iTIP: REQUEST·REPLY·CANCEL), RFC 6047 (메일로 보내는 iTIP).
// Exchange 계정은 Graph가 회의를 다루므로 여기를 쓰지 않는다.

public struct ICSInvite: Equatable, Sendable {
    public struct Attendee: Equatable, Sendable {
        public var email: String
        public var name: String?
        /// NEEDS-ACTION, ACCEPTED, TENTATIVE, DECLINED
        public var partstat: String
    }

    /// REQUEST(초대·바뀐 초대), CANCEL(취소), REPLY(누군가의 답) …
    public var method: String
    public var uid: String
    public var sequence: Int
    public var summary: String?
    public var location: String?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// 종일 일정의 날짜 "2026-11-10" (시간대를 타지 않게 따로 둔다)
    public var startDay: String?
    public var endDay: String?
    public var organizerEmail: String?
    public var organizerName: String?
    public var attendees: [Attendee]
    /// 반복 회의 규칙 (있으면)
    public var recurrence: String?

    /// 답장에 그대로 옮길 원본 줄 (펼친 줄): DTSTART, DTEND, RECURRENCE-ID, ORGANIZER
    var rawLines: [String: String] = [:]
    /// 원본의 VTIMEZONE 덩어리 (TZID 시각을 답장에서도 읽을 수 있게)
    var timeZoneBlocks: [String] = []

    // MARK: 읽기

    /// 첨부 가운데 일정 파일을 찾아 읽는다 (text/calendar, application/ics, 이름이 .ics).
    public static func find(in attachments: [(name: String, contentType: String, data: Data)]) -> ICSInvite? {
        for a in attachments {
            let type = a.contentType.lowercased()
            guard type == "text/calendar" || type == "application/ics" || a.name.lowercased().hasSuffix(".ics") else { continue }
            let text = String(data: a.data, encoding: .utf8) ?? String(data: a.data, encoding: .isoLatin1) ?? ""
            if let invite = parse(text) { return invite }
        }
        return nil
    }

    public static func parse(_ text: String) -> ICSInvite? {
        let lines = unfold(text)
        var method = "REQUEST"
        var inEvent = false, eventDone = false, inAlarm = false
        var zoneDepth = 0
        var zoneLines: [String] = []
        var zones: [String] = []
        var zoneOffsets: [String: Int] = [:]   // TZID → 표준 시간 오프셋(초): 모르는 TZID일 때
        var currentZoneID: String?
        var props: [(name: String, params: [String: String], value: String, raw: String)] = []
        var attendees: [Attendee] = []
        for line in lines {
            let upper = line.uppercased()
            if upper == "BEGIN:VTIMEZONE" { zoneDepth = 1; zoneLines = [line]; currentZoneID = nil; continue }
            if zoneDepth > 0 {
                zoneLines.append(line)
                if upper.hasPrefix("TZID:") { currentZoneID = String(line.dropFirst(5)) }
                if upper.hasPrefix("TZOFFSETTO:"), let id = currentZoneID, zoneOffsets[id] == nil {
                    zoneOffsets[id] = offsetSeconds(String(line.dropFirst(11)))
                }
                if upper == "END:VTIMEZONE" { zoneDepth = 0; zones.append(zoneLines.joined(separator: "\r\n")) }
                continue
            }
            if upper.hasPrefix("METHOD:") { method = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces).uppercased() }
            // 반복 회의의 예외(RECURRENCE-ID가 있는 두 번째 VEVENT)는 건너뛰고 첫 일정만 본다
            if upper == "BEGIN:VEVENT" { if !eventDone { inEvent = true }; continue }
            if upper == "END:VEVENT" { if inEvent { eventDone = true }; inEvent = false; continue }
            // 알림(VALARM) 안의 줄은 일정의 값이 아니다
            if upper == "BEGIN:VALARM" { inAlarm = true; continue }
            if upper == "END:VALARM" { inAlarm = false; continue }
            guard inEvent, !inAlarm, let p = property(line) else { continue }
            if p.name == "ATTENDEE" {
                attendees.append(Attendee(email: mailto(p.value), name: p.params["CN"].map(unquote),
                                          partstat: (p.params["PARTSTAT"] ?? "NEEDS-ACTION").uppercased()))
            } else {
                props.append((p.name, p.params, p.value, line))
            }
        }
        func first(_ name: String) -> (params: [String: String], value: String, raw: String)? {
            props.first { $0.name == name }.map { ($0.params, $0.value, $0.raw) }
        }
        guard let uid = first("UID")?.value, !uid.isEmpty,
              let dtstart = first("DTSTART"),
              let start = date(dtstart.value, params: dtstart.params, zoneOffsets: zoneOffsets) else { return nil }
        let allDay = dtstart.params["VALUE"]?.uppercased() == "DATE" || dtstart.value.count == 8
        var end: Date
        if let dtend = first("DTEND"), let e = date(dtend.value, params: dtend.params, zoneOffsets: zoneOffsets) {
            end = e
        } else if let d = first("DURATION").flatMap({ duration($0.value) }) {
            end = start.addingTimeInterval(d)
        } else {
            end = allDay ? start.addingTimeInterval(86_400) : start
        }
        end = max(end, start)
        var invite = ICSInvite(method: method, uid: uid, sequence: Int(first("SEQUENCE")?.value ?? "") ?? 0,
                               summary: first("SUMMARY").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
                               location: first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
                               start: start, end: end, isAllDay: allDay,
                               organizerEmail: first("ORGANIZER").map { mailto($0.value) },
                               organizerName: first("ORGANIZER")?.params["CN"].map(unquote),
                               attendees: attendees, recurrence: first("RRULE")?.value)
        if allDay {
            invite.startDay = day(dtstart.value)
            invite.endDay = first("DTEND").flatMap { day($0.value) }
        }
        for name in ["DTSTART", "DTEND", "RECURRENCE-ID", "ORGANIZER"] { invite.rawLines[name] = first(name)?.raw }
        invite.timeZoneBlocks = zones
        return invite
    }

    /// 수락·거절할 수 있는 초대인가: REQUEST이고 내가 주최자가 아니다
    public func isRequest(me: [String]) -> Bool {
        method == "REQUEST" && !isOrganizer(me: me)
    }

    public func isOrganizer(me: [String]) -> Bool {
        guard let o = organizerEmail?.lowercased() else { return false }
        return me.contains { $0.lowercased() == o }
    }

    /// 초대 안에 적힌 내 응답 (Graph 값으로): 받은 초대는 대개 NEEDS-ACTION
    public func myResponse(me: [String]) -> String {
        if isOrganizer(me: me) { return "organizer" }
        let mine = attendees.first { a in me.contains { $0.lowercased() == a.email.lowercased() } }
        switch mine?.partstat {
        case "ACCEPTED": return "accepted"
        case "TENTATIVE": return "tentativelyAccepted"
        case "DECLINED": return "declined"
        default: return "notResponded"
        }
    }

    /// 앱 안의 일정 id: 계정마다, 회의(UID)마다 하나. 바뀐 초대·취소도 같은 id라 맥 캘린더의 같은 일정을 찾는다.
    public static func eventID(account: String, uid: String) -> String {
        "ics:\(account):" + (uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uid)
    }

    public static func isEventID(_ id: String) -> Bool { id.hasPrefix("ics:") }

    /// 회의 막대와 맥 캘린더가 쓰는 일정
    public func mailEvent(id: String, response: String) -> MailEvent {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'.0000000'"
        let s: GraphDateTime, e: GraphDateTime
        if isAllDay, let startDay {
            // 종일: 날짜만 (이 Mac의 시간대로 읽게 해 하루가 밀리지 않는다)
            let zone = TimeZone.current.identifier
            s = GraphDateTime(dateTime: startDay + "T00:00:00.0000000", timeZone: zone)
            let endDay = endDay ?? Self.nextDay(startDay)
            e = GraphDateTime(dateTime: endDay + "T00:00:00.0000000", timeZone: zone)
        } else {
            s = GraphDateTime(dateTime: utc.string(from: start), timeZone: "UTC")
            e = GraphDateTime(dateTime: utc.string(from: end), timeZone: "UTC")
        }
        return MailEvent(id: id, subject: summary, start: s, end: e, location: location, isAllDay: isAllDay, response: response)
    }

    /// 본문이 빈 초대·응답·취소 메일에 보일 설명 (맥 Mail처럼): "Kim님이 회의를 거절했습니다." + 제목, 일시, 장소
    public func summaryText() -> String {
        let title = summary ?? L("회의")
        var lines: [String] = []
        switch method {
        case "REPLY":
            let a = attendees.first
            let who = a.flatMap { $0.name.flatMap { $0.isEmpty ? nil : $0 } ?? $0.email } ?? L("참석자")
            switch a?.partstat {
            case "ACCEPTED": lines.append(L("\(who)님이 회의를 수락했습니다."))
            case "TENTATIVE": lines.append(L("\(who)님이 회의에 미정으로 답했습니다."))
            case "DECLINED": lines.append(L("\(who)님이 회의를 거절했습니다."))
            default: lines.append(L("\(who)님이 회의에 답했습니다."))
            }
        case "CANCEL":
            lines.append(L("주최자가 회의를 취소했습니다."))
        default:
            let who = organizerName.flatMap { $0.isEmpty ? nil : $0 } ?? organizerEmail
            lines.append(who.map { L("\($0)님의 회의 초대") } ?? L("회의 초대"))
        }
        lines.append("")
        lines.append(title)
        let when = mailEvent(id: "-", response: "").whenText()
        if !when.isEmpty { lines.append(when) }
        if let location { lines.append(location) }
        return lines.joined(separator: "\n")
    }

    // MARK: 답장 (METHOD:REPLY)

    /// iTIP 답장 일정 파일. 줄 끝은 CRLF, 75바이트에서 접는다.
    public func replyCalendar(attendee: MailAddress, response: MeetingResponse, now: Date = Date()) -> String {
        let partstat: String
        switch response {
        case .accept: partstat = "ACCEPTED"
        case .tentativelyAccept: partstat = "TENTATIVE"
        case .decline: partstat = "DECLINED"
        }
        var cn = ""
        if let name = attendee.name, !name.isEmpty { cn = ";CN=\"\(name.replacingOccurrences(of: "\"", with: "'"))\"" }
        var lines = ["BEGIN:VCALENDAR", "PRODID:-//FAKUKU Lab//FAKUKU Mail//EN", "VERSION:2.0", "CALSCALE:GREGORIAN", "METHOD:REPLY"]
        lines += timeZoneBlocks
        lines += ["BEGIN:VEVENT", "UID:\(uid)", "SEQUENCE:\(sequence)", "DTSTAMP:\(Self.stamp(now))"]
        for name in ["DTSTART", "DTEND", "RECURRENCE-ID", "ORGANIZER"] { if let raw = rawLines[name] { lines.append(raw) } }
        if let summary { lines.append("SUMMARY:" + Self.escape(summary)) }
        lines.append("ATTENDEE;PARTSTAT=\(partstat)\(cn):mailto:\(attendee.address)")
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.flatMap { $0.components(separatedBy: "\r\n") }.map(Self.fold).joined(separator: "\r\n") + "\r\n"
    }

    /// 주최자에게 보낼 메일 (글 + 일정 파일). 주최자가 없으면 nil.
    public func replyMIME(from me: MailAddress, response: MeetingResponse, now: Date = Date()) -> Data? {
        guard let organizer = organizerEmail, !organizer.isEmpty else { return nil }
        let title = summary ?? L("회의")
        let subject: String
        let sentence: String
        let who = me.name.flatMap { $0.isEmpty ? nil : $0 } ?? me.address
        switch response {
        case .accept: subject = L("수락: \(title)"); sentence = L("\(who)님이 회의를 수락했습니다.")
        case .tentativelyAccept: subject = L("미정: \(title)"); sentence = L("\(who)님이 회의에 미정으로 답했습니다.")
        case .decline: subject = L("거절: \(title)"); sentence = L("\(who)님이 회의를 거절했습니다.")
        }
        let boundary = MIMEBuilder.boundary("ics")
        let calendar = replyCalendar(attendee: me, response: response, now: now)
        let domain = me.address.split(separator: "@").last.map(String.init) ?? "fakuku.local"
        var head = [
            "From: " + MIMEBuilder.header(me),
            "To: " + MIMEBuilder.header(MailAddress(name: organizerName, address: organizer)),
            "Subject: " + MIMEBuilder.encodedWords(subject),
            "Date: " + MIMEBuilder.rfc5322Date(now),
            "Message-ID: <\(UUID().uuidString)@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
        ]
        head.append("")
        let body = [
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            MIMEBuilder.base64Lines(Data(sentence.utf8)),
            "--\(boundary)",
            "Content-Type: text/calendar; charset=utf-8; method=REPLY",
            "Content-Transfer-Encoding: base64",
            "",
            MIMEBuilder.base64Lines(Data(calendar.utf8)),
            "--\(boundary)--",
            "",
        ]
        return Data((head + body).joined(separator: "\r\n").utf8)
    }

    // MARK: 도움 함수

    /// 접힌 줄 펴기: CRLF(또는 LF) 다음 공백·탭은 앞 줄에 붙는다
    static func unfold(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true) {
            if let f = raw.first, f == " " || f == "\t", !out.isEmpty {
                out[out.count - 1] += raw.dropFirst()
            } else {
                out.append(String(raw))
            }
        }
        return out
    }

    /// "DTSTART;TZID=Asia/Seoul:20261110T100000" → 이름, 매개변수, 값 (따옴표 안의 : ; 는 나누지 않는다)
    static func property(_ line: String) -> (name: String, params: [String: String], value: String)? {
        var quoted = false
        var colon: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { quoted.toggle() }
            if c == ":" && !quoted { colon = i; break }
        }
        guard let colon else { return nil }
        let head = String(line[..<colon]), value = String(line[line.index(after: colon)...])
        var parts: [String] = []
        var current = ""
        quoted = false
        for c in head {
            if c == "\"" { quoted.toggle() }
            if c == ";" && !quoted { parts.append(current); current = "" } else { current.append(c) }
        }
        parts.append(current)
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            params[p[..<eq].uppercased()] = String(p[p.index(after: eq)...])
        }
        return (parts[0].uppercased(), params, value)
    }

    static func mailto(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        return v.lowercased().hasPrefix("mailto:") ? String(v.dropFirst(7)) : v
    }

    static func unquote(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

    static func unescape(_ s: String) -> String {
        var out = "", escaping = false
        for c in s {
            if escaping {
                switch c {
                case "n", "N": out.append("\n")
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// 75바이트가 넘는 줄은 CRLF + 공백으로 접는다 (UTF-8 글자 중간에서 자르지 않는다)
    static func fold(_ line: String) -> String {
        var out: [String] = []
        var current = ""
        var bytes = 0
        for ch in line {
            let n = String(ch).utf8.count
            let limit = out.isEmpty ? 75 : 74
            if bytes + n > limit { out.append(current); current = ""; bytes = 0 }
            current.append(ch); bytes += n
        }
        out.append(current)
        return out.joined(separator: "\r\n ")
    }

    /// 20261110T100000Z(UTC), 20261110T100000 + TZID, 20261110(종일)
    static func date(_ value: String, params: [String: String], zoneOffsets: [String: Int]) -> Date? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if v.count == 8 {
            // 종일: 이 Mac의 그날 0시
            f.timeZone = .current
            f.dateFormat = "yyyyMMdd"
            return f.date(from: v)
        }
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        if v.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: String(v.dropLast()))
        }
        if let tzid = params["TZID"].map(unquote) {
            f.timeZone = zone(tzid) ?? zoneOffsets[tzid].flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
        } else {
            f.timeZone = .current   // 떠다니는 시각: 보는 사람의 시간대
        }
        return f.date(from: v)
    }

    /// IANA 이름, 또는 Outlook이 쓰는 Windows 시간대 이름 가운데 흔한 것
    static func zone(_ tzid: String) -> TimeZone? {
        if let z = TimeZone(identifier: tzid) { return z }
        let windows: [String: String] = [
            "Korea Standard Time": "Asia/Seoul", "Tokyo Standard Time": "Asia/Tokyo",
            "China Standard Time": "Asia/Shanghai", "Taipei Standard Time": "Asia/Taipei",
            "Singapore Standard Time": "Asia/Singapore", "UTC": "UTC", "GMT Standard Time": "Europe/London",
            "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
            "Central Europe Standard Time": "Europe/Budapest", "Eastern Standard Time": "America/New_York",
            "Central Standard Time": "America/Chicago", "Mountain Standard Time": "America/Denver",
            "Pacific Standard Time": "America/Los_Angeles", "India Standard Time": "Asia/Kolkata",
            "AUS Eastern Standard Time": "Australia/Sydney",
        ]
        return windows[tzid].flatMap(TimeZone.init(identifier:))
    }

    /// "+0900" → 32400
    static func offsetSeconds(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 5, let sign = t.first, sign == "+" || sign == "-",
              let h = Int(t.dropFirst().prefix(2)), let m = Int(t.dropFirst(3).prefix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }

    /// "PT1H30M", "P1D" → 초
    static func duration(_ s: String) -> TimeInterval? {
        var total = 0.0, number = ""
        for c in s.uppercased() {
            if c.isNumber { number.append(c); continue }
            let n = Double(number) ?? 0
            switch c {
            case "W": total += n * 604_800
            case "D": total += n * 86_400
            case "H": total += n * 3_600
            case "M": total += n * 60
            case "S": total += n
            default: break
            }
            number = ""
        }
        return total > 0 ? total : nil
    }

    /// "20261110" 또는 "20261110T..." → "2026-11-10"
    static func day(_ value: String) -> String? {
        let digits = value.prefix(8)
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
    }

    static func nextDay(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        return f.string(from: d.addingTimeInterval(86_400))
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
