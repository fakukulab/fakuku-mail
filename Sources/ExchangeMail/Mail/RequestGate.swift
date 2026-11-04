import Foundation

// Exchange Online(Graph)의 사서함 한도: 한 사서함에 동시에 4개 요청까지, 그 밖에 짧은 시간의 요청 수.
// 넘으면 429 "요청이 너무 많습니다"가 온다. 본문·첨부·대화·미리 받기·본문 그림을 한꺼번에 띄우면 쉽게 넘는다.

/// 동시에 나가는 Graph 요청 수를 묶는다 (먼저 온 요청부터).
final class RequestGate {
    let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // 자리가 나면 release가 이 요청에 자리를 넘긴다 (running은 그대로).
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// 지금 바쁜가 (미리 받기는 바쁘면 쉰다)
    var isBusy: Bool { running >= limit - 1 || !waiters.isEmpty }
}

/// 서버가 최근에 막았는가. 막힌 뒤 2분 동안은 미리 받기 같은 급하지 않은 요청을 쉰다.
enum GraphThrottle {
    private(set) static var until: Date?

    static func note(retryAfter seconds: Double) {
        until = Date().addingTimeInterval(max(120, seconds))
    }

    static var isCalm: Bool { until.map { Date() >= $0 } ?? true }
}
