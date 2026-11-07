import Foundation
import Testing
@testable import ExchangeMailKit

// 1.0.2 여러 통을 읽음으로: Graph 묶음 요청

@Test("묶음은 20개씩 나뉜다")
func batchChunks() {
    let ids = (0..<45).map { "m\($0)" }
    let chunks = GraphBatch.chunks(ids)
    #expect(chunks.map(\.count) == [20, 20, 5])
    #expect(chunks.flatMap { $0 } == ids)
    #expect(GraphBatch.chunks([]).isEmpty)
}

@Test("묶음 본문: 자리 번호 id, PATCH, 메일 경로, isRead")
func batchBody() throws {
    let body = GraphBatch.readRequests(["AAA=", "B/C"], read: true)
    let data = try JSONSerialization.data(withJSONObject: body)
    let back = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let requests = try #require(back["requests"] as? [[String: Any]])
    #expect(requests.count == 2)
    #expect(requests[0]["id"] as? String == "0")
    #expect(requests[1]["id"] as? String == "1")
    #expect(requests[0]["method"] as? String == "PATCH")
    #expect(requests[0]["url"] as? String == "/me/messages/AAA=")
    #expect(requests[1]["url"] as? String == "/me/messages/B%2FC")
    #expect((requests[0]["body"] as? [String: Any])?["isRead"] as? Bool == true)
    #expect((requests[0]["headers"] as? [String: String])?["Content-Type"] == "application/json")
}

@Test("묶음 응답: 성공, 막힘(다시 보내기와 기다릴 시간), 실패, 응답 없음")
func batchParse() {
    let json = """
    {"responses":[
      {"id":"1","status":429,"headers":{"Retry-After":"7"}},
      {"id":"0","status":200,"body":{}},
      {"id":"2","status":404,"body":{"error":{"code":"ErrorItemNotFound"}}},
      {"id":"3","status":503,"headers":{"retry-after":"2"}},
      {"id":"0","status":500},
      {"id":"99","status":200}
    ]}
    """
    let r = GraphBatch.parse(Data(json.utf8), ids: ["a", "b", "c", "d", "e"])
    #expect(r.done == ["a"])
    #expect(r.retry == ["b", "d", "e"])   // e는 응답이 없어 다시 보낸다
    #expect(r.retryAfter == 7)
    #expect(r.failedStatus == 404)
}

@Test("읽을 수 없는 묶음 응답은 모두 다시 보낸다")
func batchParseGarbage() {
    let r = GraphBatch.parse(Data("oops".utf8), ids: ["a", "b"])
    #expect(r.done.isEmpty)
    #expect(r.retry == ["a", "b"])
}
