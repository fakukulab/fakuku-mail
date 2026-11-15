import Foundation
import Testing
@testable import ExchangeMailKit

// S-078 스마트 메일상자는 최근 100통이 아니라 모든 메일에서 찾는다

@Test("스마트 메일상자 요청은 1,000통씩 받고 다음 쪽을 따라간다")
func smartCollectPageSize() {
    let r = GraphQuery.collect(filter: "isRead eq false")
    #expect(r.query["$top"] == "1000")
    #expect(r.query["$filter"] == "isRead eq false")
    #expect(GraphQuery.collectPageSize * GraphQuery.collectMaxPages >= 100_000)
}

@Test("IMAP 머리글의 중요도를 Graph와 같은 값으로 읽는다")
func imapImportance() {
    #expect(IMAP.importance(importance: "High", priority: nil) == "high")
    #expect(IMAP.importance(importance: nil, priority: "1 (Highest)") == "high")
    #expect(IMAP.importance(importance: nil, priority: "5") == "low")
    #expect(IMAP.importance(importance: nil, priority: nil) == "normal")
}

// S-079 한 번 찾은 결과는 저장해 두고 새로 받은 메일만 더 찾는다


private func mail(_ id: String, _ day: Int, read: Bool = false) -> MailMessage {
    var m = MailMessage(id: id, subject: "견적 \(id)", from: Recipient(name: "김", address: "kim@x.com"),
                        toRecipients: [], ccRecipients: [], receivedDateTime: Date(timeIntervalSince1970: Double(day) * 86_400),
                        bodyPreview: "", hasAttachments: false)
    m.isRead = read
    return m
}

@Test("저장된 결과에 새 메일을 더한다: 같은 메일은 새 것으로, 최근 순")
func smartMerge() {
    let merged = SmartMailbox.merge([mail("a", 1), mail("b", 2, read: false)], [mail("b", 2, read: true), mail("c", 3)])
    #expect(merged.map(\.id) == ["c", "b", "a"])
    #expect(merged[1].isRead == true)
}

@Test("조건이 바뀌면 다른 결과, 읽지 않음·깃발은 매번 찾는다")
func smartResultKey() {
    let a = SmartMailbox(id: "s1", name: "a", conditions: [.init(field: .sender, value: "Kim ")])
    var b = a
    b.name = "이름만 바꿈"
    #expect(a.resultKey(vips: [], folderID: nil) == b.resultKey(vips: [], folderID: nil))
    b.conditions = [.init(field: .sender, value: "lee")]
    #expect(a.resultKey(vips: [], folderID: nil) != b.resultKey(vips: [], folderID: nil))
    #expect(a.reusesResults)
    #expect(!SmartMailbox(name: "u", conditions: [.init(field: .unread)]).reusesResults)
}

@Test("저장된 스마트 메일상자 결과를 고친다")
func smartListUpdate() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "smart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = MailCache(root: dir)
    cache.saveSmartList(.init(messages: [mail("a", 1), mail("b", 2)], scannedAt: Date(timeIntervalSince1970: 10)), key: "k")
    cache.updateSmartLists { list in
        list.removeAll { $0.id == "a" }
        return true
    }
    let saved = try #require(cache.smartList(key: "k"))
    #expect(saved.messages.map(\.id) == ["b"])
    #expect(saved.scannedAt == Date(timeIntervalSince1970: 10))
}
