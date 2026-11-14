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
