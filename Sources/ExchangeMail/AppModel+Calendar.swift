import AppKit
import ExchangeMailKit
import Foundation

// S-056 수락한 회의를 맥 캘린더에 (Mail/MacCalendar.swift).

extension AppModel {
    /// 회의 응답 뒤: 수락·미정이면 맥 캘린더에 넣고, 거절이면 앱이 넣었던 일정을 지운다.
    /// 설정 > 계정 > 맥 캘린더를 끄면 하지 않는다. 데모·셀프 테스트에서는 실제 캘린더를 건드리지 않는다.
    func syncMacCalendar(after response: MeetingResponse, event: MailEvent, subject: String?) async {
        guard !Store.isDemo, Prefs.bool(Prefs.calendarAddAccepted, true),
              let entry = CalendarEntry(event: event, fallbackTitle: subject) else { return }
        let outcome: MacCalendar.Outcome?
        if response == .decline {
            outcome = await MacCalendar.shared.removeAdded(entry)
        } else {
            outcome = await MacCalendar.shared.add(entry, calendarID: Prefs.string(Prefs.calendarTarget, ""))
        }
        if let outcome { show(outcome, for: event.id) }
    }

    /// 메시지 > 맥 캘린더에 추가: 지금 회의 초대를 직접 넣는다 (설정과 상관없이).
    func addMeetingToMacCalendar() async {
        guard !Store.isDemo, let m = detail, let event = m.event,
              let entry = CalendarEntry(event: event, fallbackTitle: m.subject) else { return }
        show(await MacCalendar.shared.add(entry, calendarID: Prefs.string(Prefs.calendarTarget, "")), for: event.id)
    }

    private func show(_ outcome: MacCalendar.Outcome, for eventID: String) {
        macCalendarStatus[eventID] = outcome
        switch outcome {
        case .denied:
            noticeMessage = L("맥 캘린더에 접근할 수 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 FAKUKU Mail을 켜 주세요.")
            MacCalendar.openPrivacySettings()
        case .failed(let message):
            errorMessage = L("맥 캘린더에 넣지 못했습니다: \(message)")
        default:
            break
        }
    }
}

extension MacCalendar.Outcome {
    /// 회의 막대의 짧은 글
    var label: String? {
        switch self {
        case .added(let calendar): L("맥 캘린더에 추가함 (\(calendar))")
        case .alreadyThere: L("맥 캘린더에 있음")
        case .removed: L("맥 캘린더에서 지움")
        case .denied, .failed: nil
        }
    }
}
