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
        /// 앱이 넣은 일정을 바뀐 회의에 맞춰 고쳤다 (캘린더 이름)
        case updated(String)
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

    /// 설정에 보일 권한 상태 (어디서 막혔는지 알 수 있게)
    var statusText: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: L("허용됨")
        case .notDetermined: L("아직 묻지 않음")
        case .writeOnly: L("추가만 허용됨: 같은 회의를 찾으려면 전체 접근이 필요합니다")
        case .denied: L("거부됨: 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 켜 주세요")
        case .restricted: L("이 Mac에서 제한됨")
        @unknown default: L("알 수 없음")
        }
    }

    /// 시험: 1시간 뒤 5분짜리 일정을 넣었다가 바로 지운다. 결과 글.
    func selfCheck(calendarID: String) async -> String {
        guard await requestAccess() else { return L("권한이 없습니다: \(statusText)") }
        let calendars = writableCalendars()
        guard !calendars.isEmpty else { return L("일정을 넣을 수 있는 캘린더가 없습니다.") }
        let target = store.calendar(withIdentifier: calendarID).flatMap { $0.source.sourceType == .exchange ? nil : $0 }
            ?? store.defaultCalendarForNewEvents.flatMap { $0.source.sourceType == .exchange ? nil : $0 } ?? calendars[0]
        let event = EKEvent(eventStore: store)
        event.title = L("FAKUKU Mail 시험 일정")
        event.startDate = Date().addingTimeInterval(3_600)
        event.endDate = event.startDate.addingTimeInterval(300)
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent, commit: true)
            try store.remove(event, span: .thisEvent, commit: true)
            return L("넣고 지우기 성공 (\(target.title), 캘린더 \(calendars.count)개)")
        } catch {
            return L("넣지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 처음이면 권한을 묻는다.
    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined:
            // 완료 콜백 방식: 일정 저장소(EKEventStore)를 다른 스레드로 넘기지 않는다 (Swift 6 경합 검사).
            let granted = await withCheckedContinuation { continuation in
                // @Sendable: 응답은 다른 스레드에서 온다. 메인 액터 클로저로 받으면 Swift 6 실행 검사에 걸린다
                store.requestFullAccessToEvents { @Sendable granted, _ in continuation.resume(returning: granted) }
            }
            if granted { store.reset() }   // 권한 전에 만든 저장소는 캘린더가 비어 보일 수 있다
            return granted
        default: return false
        }
    }

    /// 일정을 넣을 수 있는 캘린더 (설정의 고르기 목록)
    /// Exchange 캘린더는 뺀다: 거기 넣으면 Exchange 서버에 회의가 하나 더 생긴다 (회의는 이미 서버 일정에 있다).
    func writableCalendars() -> [EKCalendar] {
        guard hasAccess else { return [] }
        var list = store.calendars(for: .event)
        if list.isEmpty {
            // 시스템 설정에서 방금 허용했으면 저장소가 아직 비어 있다
            store.reset()
            list = store.calendars(for: .event)
        }
        return list.filter { $0.allowsContentModifications && $0.source.sourceType != .exchange }
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// 회의를 넣는다. 같은 회의가 어느 캘린더에든 이미 있으면(앱이 넣었거나 Exchange 동기화로 들어왔거나) 넣지 않는다.
    func add(_ entry: CalendarEntry, calendarID: String) async -> Outcome {
        guard await requestAccess() else { return .denied }
        if let existing = find(entry) {
            // 앱이 넣은 일정인데 주최자가 시각·제목·장소를 바꿨으면 고친다 (그대로 두면 예전 시각에 남는다)
            if existing.url == entry.marker,
               entry.needsUpdate(title: existing.title, start: existing.startDate, end: existing.endDate,
                                 isAllDay: existing.isAllDay, location: existing.location) {
                existing.title = entry.title
                existing.startDate = entry.start
                existing.endDate = entry.end
                existing.isAllDay = entry.isAllDay
                existing.location = entry.location
                do {
                    try store.save(existing, span: .thisEvent, commit: true)
                    return .updated(existing.calendar?.title ?? "")
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            return .alreadyThere(existing.calendar?.title ?? "")
        }
        let chosen = store.calendar(withIdentifier: calendarID) ?? store.defaultCalendarForNewEvents
        // Exchange 캘린더에는 넣지 않는다 (서버에 회의가 하나 더 생긴다): 넣을 수 있는 첫 캘린더로
        let target = chosen.flatMap { $0.source.sourceType == .exchange ? nil : $0 } ?? writableCalendars().first
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

    /// 이 회의가 맥 캘린더에 이미 있는가 (회의 막대를 열 때). 권한을 묻지 않는다.
    func lookup(_ entry: CalendarEntry) -> Outcome? {
        guard hasAccess, let existing = find(entry) else { return nil }
        return .alreadyThere(existing.calendar?.title ?? "")
    }

    /// 앱이 넣은 일정 가운데, 그 뒤 Exchange 동기화로 같은 회의(같은 제목·시각)가 들어온 것은 지운다.
    /// 새 메일을 확인할 때(2분마다) 부른다. 지운 수.
    @discardableResult
    func removeSyncedDuplicates(now: Date = Date()) -> Int {
        guard hasAccess else { return 0 }
        let window = store.predicateForEvents(withStart: now.addingTimeInterval(-86_400),
                                              end: now.addingTimeInterval(180 * 86_400), calendars: nil)
        let events = store.events(matching: window)
        let isMine = { (e: EKEvent) in e.url?.scheme == CalendarEntry.markerScheme }
        var removed = 0
        for e in events where isMine(e) {
            let title = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let twin = events.contains { o in
                !isMine(o) && o.isAllDay == e.isAllDay && abs(o.startDate.timeIntervalSince(e.startDate)) < 60
                    && (o.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
            }
            if twin, (try? store.remove(e, span: .thisEvent, commit: false)) != nil { removed += 1 }
        }
        if removed > 0 { try? store.commit() }
        return removed
    }

    private func find(_ entry: CalendarEntry) -> EKEvent? {
        let window = store.predicateForEvents(withStart: entry.start.addingTimeInterval(-3_600),
                                              end: entry.end.addingTimeInterval(3_600), calendars: nil)
        let events = store.events(matching: window)
        return events.first { $0.url == entry.marker }
            ?? events.first { entry.isSame(title: $0.title, start: $0.startDate, isAllDay: $0.isAllDay) }
    }
}
