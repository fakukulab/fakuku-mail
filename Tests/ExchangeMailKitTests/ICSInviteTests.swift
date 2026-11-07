import Foundation
import Testing
@testable import ExchangeMailKit

// 1.0.3 iCloud·Gmail 회의 초대 (.ics)

private let google = """
BEGIN:VCALENDAR\r
PRODID:-//Google Inc//Google Calendar 70.9054//EN\r
VERSION:2.0\r
CALSCALE:GREGORIAN\r
METHOD:REQUEST\r
BEGIN:VTIMEZONE\r
TZID:Asia/Seoul\r
BEGIN:STANDARD\r
TZOFFSETFROM:+0900\r
TZOFFSETTO:+0900\r
TZNAME:KST\r
DTSTART:19700101T000000\r
END:STANDARD\r
END:VTIMEZONE\r
BEGIN:VEVENT\r
DTSTART;TZID=Asia/Seoul:20261110T100000\r
DTEND;TZID=Asia/Seoul:20261110T113000\r
RRULE:FREQ=WEEKLY;BYDAY=TU\r
DTSTAMP:20261108T010000Z\r
ORGANIZER;CN=Kim Boss:mailto:boss@example.com\r
UID:abc123@google.com\r
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Kim Boss;\r
 X-NUM-GUESTS=0:mailto:boss@example.com\r
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;CN="Me, Jr";\r
 X-NUM-GUESTS=0:mailto:me@gmail.com\r
SEQUENCE:2\r
SUMMARY:주간 회의\\, 3분기 계획\r
LOCATION:3층 회의실\r
BEGIN:VALARM\r
ACTION:DISPLAY\r
DESCRIPTION:알림 설명\r
TRIGGER:-P0DT0H10M0S\r
END:VALARM\r
END:VEVENT\r
END:VCALENDAR\r

"""

@Test("Google 초대: 시간대, 접힌 줄, 반복, 참석자, 알림 안의 값은 무시")
func icsGoogle() throws {
    let i = try #require(ICSInvite.parse(google))
    #expect(i.method == "REQUEST" && i.uid == "abc123@google.com" && i.sequence == 2)
    #expect(i.summary == "주간 회의, 3분기 계획" && i.location == "3층 회의실")
    #expect(i.start == ISO8601DateFormatter().date(from: "2026-11-10T01:00:00Z"))
    #expect(i.end.timeIntervalSince(i.start) == 5400)
    #expect(!i.isAllDay && i.recurrence == "FREQ=WEEKLY;BYDAY=TU")
    #expect(i.organizerEmail == "boss@example.com" && i.organizerName == "Kim Boss")
    #expect(i.attendees.map(\.email) == ["boss@example.com", "me@gmail.com"])
    #expect(i.attendees[1].name == "Me, Jr" && i.attendees[1].partstat == "NEEDS-ACTION")
    #expect(i.isRequest(me: ["ME@gmail.com"]) && !i.isRequest(me: ["boss@example.com"]))
    #expect(i.myResponse(me: ["me@gmail.com"]) == "notResponded")
    #expect(i.myResponse(me: ["boss@example.com"]) == "organizer")
}

@Test("초대 → 회의 막대·맥 캘린더 일정")
func icsMailEvent() throws {
    let i = try #require(ICSInvite.parse(google))
    let id = ICSInvite.eventID(account: "acc1", uid: i.uid)
    #expect(id == ICSInvite.eventID(account: "acc1", uid: "abc123@google.com") && ICSInvite.isEventID(id))
    let e = i.mailEvent(id: id, response: "accepted")
    #expect(e.start?.date == i.start && e.end?.date == i.end && e.response == .accept)
    let entry = try #require(CalendarEntry(event: e))
    #expect(entry.title == "주간 회의, 3분기 계획" && entry.location == "3층 회의실" && entry.start == i.start)
}

@Test("UTC 시각, Windows 시간대 이름, 종일, DURATION")
func icsTimes() throws {
    let utc = try #require(ICSInvite.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u1\nDTSTART:20261110T010000Z\nDURATION:PT45M\nEND:VEVENT\nEND:VCALENDAR"))
    #expect(utc.start == ISO8601DateFormatter().date(from: "2026-11-10T01:00:00Z") && utc.end.timeIntervalSince(utc.start) == 2700)
    #expect(utc.method == "REQUEST")

    let win = try #require(ICSInvite.parse("BEGIN:VEVENT\nUID:u2\nDTSTART;TZID=\"Korea Standard Time\":20261110T100000\nEND:VEVENT"))
    #expect(win.start == ISO8601DateFormatter().date(from: "2026-11-10T01:00:00Z"))

    let custom = try #require(ICSInvite.parse("""
    BEGIN:VTIMEZONE
    TZID:Custom Zone
    BEGIN:STANDARD
    TZOFFSETTO:+0530
    END:STANDARD
    END:VTIMEZONE
    BEGIN:VEVENT
    UID:u3
    DTSTART;TZID=Custom Zone:20261110T100000
    END:VEVENT
    """))
    #expect(custom.start == ISO8601DateFormatter().date(from: "2026-11-10T04:30:00Z"))

    let allDay = try #require(ICSInvite.parse("BEGIN:VEVENT\nUID:u4\nDTSTART;VALUE=DATE:20261110\nDTEND;VALUE=DATE:20261112\nSUMMARY:워크숍\nEND:VEVENT"))
    #expect(allDay.isAllDay && allDay.startDay == "2026-11-10" && allDay.endDay == "2026-11-12")
    let entry = try #require(CalendarEntry(event: allDay.mailEvent(id: "x", response: "notResponded")))
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    #expect(entry.isAllDay && cal.component(.day, from: entry.start) == 10 && cal.component(.day, from: entry.end) == 11)

    #expect(ICSInvite.parse("BEGIN:VEVENT\nSUMMARY:no uid\nEND:VEVENT") == nil)
}

@Test("답장(METHOD:REPLY): 같은 UID·SEQUENCE·시각, 내 PARTSTAT, 75바이트 접기")
func icsReply() throws {
    let i = try #require(ICSInvite.parse(google))
    let me = MailAddress(name: "Me, Jr", address: "me@gmail.com")
    let text = i.replyCalendar(attendee: me, response: .tentativelyAccept, now: Date(timeIntervalSince1970: 0))
    #expect(text.contains("METHOD:REPLY\r\n") && text.contains("UID:abc123@google.com\r\n") && text.contains("SEQUENCE:2\r\n"))
    #expect(text.contains("DTSTART;TZID=Asia/Seoul:20261110T100000\r\n") && text.contains("BEGIN:VTIMEZONE\r\n"))
    #expect(text.contains("DTSTAMP:19700101T000000Z"))
    let back = try #require(ICSInvite.parse(text))
    #expect(back.method == "REPLY" && back.uid == i.uid && back.start == i.start)
    #expect(back.attendees.count == 1 && back.attendees[0].partstat == "TENTATIVE" && back.attendees[0].email == "me@gmail.com")
    #expect(back.attendees[0].name == "Me, Jr" && back.organizerEmail == "boss@example.com")
    for line in text.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 75) }

    let mime = try #require(i.replyMIME(from: me, response: .decline))
    let raw = String(decoding: mime, as: UTF8.self)
    #expect(raw.contains("To: Kim Boss <boss@example.com>") && raw.contains("method=REPLY"))
    let parsed = MailArchive.parse(mime)
    let ics = try #require(parsed.attachments.first { $0.contentType == "text/calendar" })
    #expect(ICSInvite.parse(String(decoding: ics.data, as: UTF8.self))?.attendees.first?.partstat == "DECLINED")
    #expect(ICSInvite.find(in: [("invite.ics", "application/octet-stream", ics.data)]) != nil)

    var noOrganizer = i
    noOrganizer.organizerEmail = nil
    #expect(noOrganizer.replyMIME(from: me, response: .accept) == nil)
}

@Test("긴 한글 줄은 글자 중간에서 자르지 않고 접는다")
func icsFold() {
    let line = "SUMMARY:" + String(repeating: "가", count: 60)
    let folded = ICSInvite.fold(line)
    #expect(ICSInvite.unfold(folded) == [line])
    for l in folded.components(separatedBy: "\r\n") { #expect(l.utf8.count <= 75) }
}

@Test("본문 없는 응답·취소 메일: 누가 어떻게 답했는지 글로, 일정 파일은 .ics 이름으로")
func icsReplyMail() throws {
    let reply = """
    BEGIN:VCALENDAR\r
    METHOD:REPLY\r
    BEGIN:VEVENT\r
    UID:t1\r
    DTSTART:20261110T010000Z\r
    DTEND:20261110T020000Z\r
    SUMMARY:테스트 미팅\r
    ORGANIZER:mailto:boss@example.com\r
    ATTENDEE;PARTSTAT=DECLINED;CN=Jyun Kim:mailto:jyun@example.com\r
    END:VEVENT\r
    END:VCALENDAR\r

    """
    let i = try #require(ICSInvite.parse(reply))
    #expect(!i.isRequest(me: ["boss@example.com"]) && !i.isRequest(me: ["jyun@example.com"]))
    let text = i.summaryText()
    #expect(text.hasPrefix("Jyun Kim님이 회의를 거절했습니다.") && text.contains("테스트 미팅"))

    var cancel = i
    cancel.method = "CANCEL"
    #expect(cancel.summaryText().hasPrefix("주최자가 회의를 취소했습니다."))

    // Outlook·Exchange 응답처럼 이름 없는 text/calendar 부분 하나뿐인 메일
    let mime = "From: a@example.com\r\nSubject: x\r\nMIME-Version: 1.0\r\nContent-Type: text/calendar; method=REPLY; charset=utf-8\r\n\r\n" + reply
    let mail = MailArchive.parse(Data(mime.utf8))
    #expect(mail.attachments.first?.name == "invite.ics")
    #expect(ICSInvite.find(in: mail.attachments.map { ($0.name, $0.contentType, $0.data) })?.method == "REPLY")
}
