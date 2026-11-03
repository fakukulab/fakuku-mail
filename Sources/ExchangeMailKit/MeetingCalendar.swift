import Foundation

// S-056 수락한 회의를 맥 캘린더에: EventKit에 넣을 일정의 값과, 같은 일정이 이미 있는지 판단하는 규칙.
// EventKit 호출은 앱(Mail/MacCalendar.swift)에 있고, 여기는 시험할 수 있는 규칙만 둔다.

public struct CalendarEntry: Equatable, Sendable {
    public var title: String
    public var start: Date
    /// 종일 일정이면 마지막 날의 끝 (EventKit 관례: 다음 날 0시의 1초 전)
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    /// 앱이 넣은 일정을 다시 찾는 표시 (EKEvent.url). 거절하면 이것으로 찾아 지운다.
    public var marker: URL

    /// Exchange 일정 → 맥 캘린더 일정. 시작 시각이 없으면 nil.
    public init?(event: MailEvent, fallbackTitle: String? = nil, calendar: Calendar = .current) {
        let title = (event.subject ?? fallbackTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? L("회의") : title
        isAllDay = event.isAllDay == true
        location = event.location?.displayName.flatMap { $0.isEmpty ? nil : $0 }
        marker = Self.marker(eventID: event.id)
        if isAllDay {
            // 종일 일정은 날짜만 본다: 시간대를 바꾸면 하루가 밀릴 수 있다.
            guard let day = event.start.flatMap({ Self.localDay($0.dateTime, calendar: calendar) }) else { return nil }
            let endDay = event.end.flatMap { Self.localDay($0.dateTime, calendar: calendar) }
                ?? calendar.date(byAdding: .day, value: 1, to: day) ?? day
            start = day
            end = max(endDay, calendar.date(byAdding: .day, value: 1, to: day) ?? endDay).addingTimeInterval(-1)
        } else {
            guard let s = event.start?.date else { return nil }
            start = s
            end = max(event.end?.date ?? s.addingTimeInterval(30 * 60), s)
        }
    }

    /// fakuku-meeting://event/<일정 id>
    public static func marker(eventID: String) -> URL {
        let encoded = eventID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "event"
        return URL(string: "fakuku-meeting://event/\(encoded)") ?? URL(string: "fakuku-meeting://event")!
    }

    /// 맥 캘린더에 이미 같은 회의가 있는가: 제목이 같고(대소문자·앞뒤 공백 무시) 시작이 1분 안이며 종일 여부가 같다.
    /// Exchange 계정이 맥 캘린더에 연결돼 있으면 같은 회의가 동기화로 들어오므로 두 번 넣지 않는다.
    public func isSame(title other: String?, start otherStart: Date, isAllDay otherAllDay: Bool) -> Bool {
        let a = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = (other ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return a == b && otherAllDay == isAllDay && abs(start.timeIntervalSince(otherStart)) < 60
    }

    /// "2026-11-05T00:00:00.0000000" → 이 Mac의 그날 0시
    static func localDay(_ dateTime: String, calendar: Calendar) -> Date? {
        let parts = dateTime.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
