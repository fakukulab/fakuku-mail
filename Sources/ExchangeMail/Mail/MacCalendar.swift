import AppKit
import EventKit
import ExchangeMailKit
import Foundation

// S-056 수락한 회의를 맥 캘린더(EventKit)에 넣는다.
// 맥 캘린더가 Exchange 계정과 동기화되지 않거나 늦을 때를 위해서다. 같은 회의가 이미 있으면 넣지 않는다.
// 권한: Info.plist의 NSCalendarsFullAccessUsageDescription (같은 일정을 찾으려면 읽기도 필요하다).

final class MacCalendar {
    static let shared = MacCalendar()
    private let store = EKEventStore()

    enum Outcome: Equatable {
        /// 새로 넣었다 (캘린더 이름)
        case added(String)
        /// 같은 회의가 이미 있다 (캘린더 이름)
        case alreadyThere(String)
        /// 앱이 넣었던 일정을 지웠다
        case removed
        /// 권한이 없다 (시스템 설정 > 개인정보 보호 및 보안 > 캘린더)
        case denied
        case failed(String)
    }

    /// 시스템 설정 > 개인정보 보호 및 보안 > 캘린더
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// 처음이면 권한을 묻는다.
    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined:
            // 완료 콜백 방식: 일정 저장소(EKEventStore)를 다른 스레드로 넘기지 않는다 (Swift 6 경합 검사).
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
            }
        default: return false
        }
    }

    /// 일정을 넣을 수 있는 캘린더 (설정의 고르기 목록)
    func writableCalendars() -> [EKCalendar] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// 회의를 넣는다. 같은 회의가 어느 캘린더에든 이미 있으면(앱이 넣었거나 Exchange 동기화로 들어왔거나) 넣지 않는다.
    func add(_ entry: CalendarEntry, calendarID: String) async -> Outcome {
        guard await requestAccess() else { return .denied }
        if let existing = find(entry) { return .alreadyThere(existing.calendar?.title ?? "") }
        let target = store.calendar(withIdentifier: calendarID) ?? store.defaultCalendarForNewEvents
        guard let target, target.allowsContentModifications else {
            return .failed(L("일정을 넣을 수 있는 캘린더가 없습니다."))
        }
        let event = EKEvent(eventStore: store)
        event.title = entry.title
        event.startDate = entry.start
        event.endDate = entry.end
        event.isAllDay = entry.isAllDay
        event.location = entry.location
        event.url = entry.marker
        event.notes = L("FAKUKU Mail에서 수락한 회의")
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return .added(target.title)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 거절했으면 앱이 넣었던 일정만 지운다 (Exchange 동기화로 들어온 일정은 건드리지 않는다).
    func removeAdded(_ entry: CalendarEntry) async -> Outcome? {
        guard hasAccess else { return nil }
        let window = store.predicateForEvents(withStart: entry.start.addingTimeInterval(-86_400),
                                              end: entry.end.addingTimeInterval(86_400), calendars: nil)
        let mine = store.events(matching: window).filter { $0.url == entry.marker }
        guard !mine.isEmpty else { return nil }
        do {
            for e in mine { try store.remove(e, span: .thisEvent, commit: false) }
            try store.commit()
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 이 회의가 맥 캘린더에 있는가 (MeetingBar의 표시)
    func contains(_ entry: CalendarEntry) -> Bool {
        hasAccess && find(entry) != nil
    }

    private func find(_ entry: CalendarEntry) -> EKEvent? {
        let window = store.predicateForEvents(withStart: entry.start.addingTimeInterval(-3_600),
                                              end: entry.end.addingTimeInterval(3_600), calendars: nil)
        let events = store.events(matching: window)
        return events.first { $0.url == entry.marker }
            ?? events.first { entry.isSame(title: $0.title, start: $0.startDate, isAllDay: $0.isAllDay) }
    }
}
