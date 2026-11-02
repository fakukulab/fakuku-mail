import Foundation

// MARK: 회의 초대 (S-038)

/// Graph dateTimeTimeZone: `{ "dateTime": "2026-11-05T10:00:00.0000000", "timeZone": "UTC" }`
public struct GraphDateTime: Codable, Hashable, Sendable {
    public var dateTime: String
    public var timeZone: String?

    public init(dateTime: String, timeZone: String?) {
        self.dateTime = dateTime
        self.timeZone = timeZone
    }

    /// 시각. 시간대가 UTC이거나 없으면 UTC로, 그 밖의 IANA 이름이면 그 시간대로 읽는다.
    public var date: Date? {
        let trimmed = dateTime.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let zone = timeZone.flatMap { $0.uppercased() == "UTC" ? TimeZone(identifier: "UTC") : TimeZone(identifier: $0) }
        f.timeZone = zone ?? TimeZone(identifier: "UTC")
        return f.date(from: trimmed.replacingOccurrences(of: "Z", with: ""))
    }
}

public struct MailEvent: Codable, Hashable, Sendable {
    public struct Location: Codable, Hashable, Sendable {
        public var displayName: String?
        public init(displayName: String?) { self.displayName = displayName }
    }
    public struct ResponseStatus: Codable, Hashable, Sendable {
        public var response: String?
        public init(response: String?) { self.response = response }
    }

    public var id: String
    public var subject: String?
    public var start: GraphDateTime?
    public var end: GraphDateTime?
    public var location: Location?
    public var isAllDay: Bool?
    public var responseStatus: ResponseStatus?

    public init(id: String, subject: String?, start: GraphDateTime?, end: GraphDateTime?,
                location: String? = nil, isAllDay: Bool? = false, response: String? = "notResponded") {
        self.id = id
        self.subject = subject
        self.start = start
        self.end = end
        self.location = location.map { Location(displayName: $0) }
        self.isAllDay = isAllDay
        self.responseStatus = ResponseStatus(response: response)
    }

    /// "11월 5일 (목) 오전 10:00 – 오전 11:00", 종일이면 "11월 5일 (목) 종일"
    public func whenText(timeZone: TimeZone = .current) -> String {
        guard let s = start?.date else { return "" }
        let korean = Locale(identifier: "ko_KR")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = Date.FormatStyle(locale: korean, calendar: cal, timeZone: timeZone).month(.defaultDigits).day().weekday(.abbreviated)
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: korean, calendar: cal, timeZone: timeZone)
        if isAllDay == true { return "\(s.formatted(day)) 종일" }
        guard let e = end?.date else { return "\(s.formatted(day)) \(s.formatted(time))" }
        let sameDay = cal.isDate(s, inSameDayAs: e)
        return sameDay
            ? "\(s.formatted(day)) \(s.formatted(time)) – \(e.formatted(time))"
            : "\(s.formatted(day)) \(s.formatted(time)) – \(e.formatted(day)) \(e.formatted(time))"
    }

    /// 이미 답한 것: accepted, tentativelyAccepted, declined
    public var response: MeetingResponse? { responseStatus?.response.flatMap(MeetingResponse.init(graphValue:)) }
}

public enum MeetingResponse: String, CaseIterable, Sendable {
    case accept, tentativelyAccept, decline

    /// `POST /me/events/{id}/<path>`
    public var path: String { rawValue }

    public var label: String {
        switch self {
        case .accept: "수락"
        case .tentativelyAccept: "미정"
        case .decline: "거절"
        }
    }

    public var doneLabel: String {
        switch self {
        case .accept: "수락함"
        case .tentativelyAccept: "미정으로 답함"
        case .decline: "거절함"
        }
    }

    init?(graphValue: String) {
        switch graphValue {
        case "accepted": self = .accept
        case "tentativelyAccepted": self = .tentativelyAccept
        case "declined": self = .decline
        default: return nil
        }
    }
}

// MARK: 예약 보내기 (S-037)

public enum ScheduledSend {
    /// Exchange의 지연 발송 속성 PidTagDeferredSendTime
    public static let propertyID = "SystemTime 0x3FEF"

    /// 초안에 붙일 PATCH 본문: `{"singleValueExtendedProperties":[{"id":"SystemTime 0x3FEF","value":"...Z"}]}`
    public static func patchBody(sendAt date: Date) -> [String: Any] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return ["singleValueExtendedProperties": [["id": propertyID, "value": f.string(from: date)]]]
    }

    public struct Preset: Equatable, Sendable {
        public var title: String
        public var date: Date
    }

    /// 오늘 오후 6시(지났으면 빼고), 내일 오전 9시, 다음 월요일 오전 9시
    public static func presets(now: Date = Date(), calendar base: Calendar = .current) -> [Preset] {
        var cal = base
        cal.locale = Locale(identifier: "ko_KR")
        func at(_ day: Date, hour: Int) -> Date? { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) }
        var out: [Preset] = []
        if let evening = at(now, hour: 18), evening > now.addingTimeInterval(5 * 60) {
            out.append(Preset(title: "오늘 오후 6:00", date: evening))
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), let morning = at(tomorrow, hour: 9) {
            out.append(Preset(title: "내일 오전 9:00", date: morning))
        }
        let monday = cal.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)
        if let monday, !out.contains(where: { $0.date == monday }) {
            out.append(Preset(title: "월요일 오전 9:00", date: monday))
        }
        return out
    }

    /// 너무 가까운(1분 이내) 시각이나 지난 시각은 예약하지 않는다.
    public static func isValid(_ date: Date, now: Date = Date()) -> Bool {
        date.timeIntervalSince(now) >= 60
    }
}
