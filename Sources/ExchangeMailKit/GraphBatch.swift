import Foundation

// MARK: Graph JSON 묶음 요청 (1.0.2)
// 여러 통을 읽음·읽지 않음으로 바꿀 때 PATCH를 한 통씩 보내지 않고 `POST /$batch` 하나에 20개까지 담는다.
// https://learn.microsoft.com/graph/json-batching
// 묶음 안의 요청은 따로따로 처리되고 따로 막힐 수 있다(429): 막힌 것만 골라 다시 보낸다.

public enum GraphBatch {
    /// Graph가 한 묶음에 받는 요청 수
    public static let limit = 20

    /// `limit`개씩 나눈다.
    public static func chunks(_ ids: [String], size: Int = limit) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// 묶음 본문. 요청 id는 `ids` 안의 자리(0, 1, 2…)다.
    public static func readRequests(_ ids: [String], read: Bool) -> [String: Any] {
        ["requests": ids.enumerated().map { index, id -> [String: Any] in
            ["id": String(index),
             "method": "PATCH",
             "url": "/me/messages/\(GraphPath.segment(id))",
             "headers": ["Content-Type": "application/json"],
             "body": ["isRead": read]]
        }]
    }

    public struct Result: Equatable, Sendable {
        /// 바뀐 메일
        public var done: [String] = []
        /// 서버가 잠시 막아 다시 보낼 메일 (429, 503)
        public var retry: [String] = []
        /// 다시 보내기 전에 기다릴 초 (묶음 안 응답의 Retry-After 가운데 가장 긴 것)
        public var retryAfter: Double?
        /// 다시 보내도 안 될 실패가 있었으면 그 상태 코드 (404 등)
        public var failedStatus: Int?
    }

    /// 묶음 응답을 읽는다. 응답이 없는 요청은 다시 보낸다.
    public static func parse(_ data: Data, ids: [String]) -> Result {
        struct Reply: Decodable {
            struct Item: Decodable {
                let id: String
                let status: Int
                let headers: [String: String]?
            }
            let responses: [Item]
        }
        var result = Result()
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            result.retry = ids
            return result
        }
        var answered = Set<Int>()
        for item in reply.responses {
            guard let index = Int(item.id), ids.indices.contains(index), answered.insert(index).inserted else { continue }
            let id = ids[index]
            switch item.status {
            case 200..<300:
                result.done.append(id)
            case 429, 503:
                result.retry.append(id)
                let advised = item.headers?.first { $0.key.lowercased() == "retry-after" }.flatMap { Double($0.value) }
                if let advised { result.retryAfter = max(result.retryAfter ?? 0, advised) }
            default:
                result.failedStatus = item.status
            }
        }
        for index in ids.indices where !answered.contains(index) { result.retry.append(ids[index]) }
        return result
    }
}
