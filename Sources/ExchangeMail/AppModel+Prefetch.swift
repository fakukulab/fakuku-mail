import ExchangeMailKit
import Foundation

// 메일 여는 속도 (성능).
// - 한 번 연 메일(본문, 첨부 목록)은 기억해 두고 다시 열 때 서버를 기다리지 않는다 (최근 60통).
// - 메일을 열면 목록의 다음·이전 메일을 미리 받아 둔다: ↓↑로 넘길 때 바로 보인다.
// - 대화(스레드)는 1분 동안 기억한다.
// 읽음·깃발처럼 바뀌는 값은 목록 줄의 값으로 덮어 보인다.

/// 열어 본 메일 (메모리, 최근 것부터 남긴다)
final class DetailCache {
    struct Entry {
        var message: MailMessage
        /// nil이면 아직 받지 않았다 (첨부가 없다고 본 메일은 [])
        var attachments: [FileAttachment]?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    /// 받는 중인 미리 받기 (같은 메일을 두 번 받지 않게)
    private(set) var inFlight: Set<String> = []
    let limit: Int

    init(limit: Int = 60) { self.limit = limit }

    func get(_ id: String) -> Entry? {
        guard let e = entries[id] else { return nil }
        touch(id)
        return e
    }

    func put(_ id: String, _ entry: Entry) {
        entries[id] = entry
        touch(id)
        while order.count > limit { entries[order.removeFirst()] = nil }
    }

    /// 서버에서 사라진 메일 (옮겨졌거나 지워졌다)
    func remove(_ id: String) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }

    func setAttachments(_ id: String, _ list: [FileAttachment]) {
        entries[id]?.attachments = list
    }

    func begin(_ id: String) -> Bool { inFlight.insert(id).inserted }
    func end(_ id: String) { inFlight.remove(id) }

    func removeAll() {
        entries = [:]
        order = []
        inFlight = []
    }

    private func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

extension AppModel {
    /// 이 메일에 첨부 목록이 필요한가 (첨부가 있거나 본문에 cid: 그림이 있으면)
    static func needsAttachments(_ m: MailMessage) -> Bool {
        (m.hasAttachments ?? false) || (m.body?.content.contains("cid:") ?? false)
    }

    /// 목록 줄의 읽음·깃발·중요도·범주로 덮는다 (기억해 둔 본문은 그 뒤에 바뀌었을 수 있다).
    func withCurrentState(_ m: MailMessage) -> MailMessage {
        guard let row = messages.first(where: { $0.id == m.id }) ?? thread.first(where: { $0.id == m.id }) else { return m }
        var out = m
        out.isRead = row.isRead
        out.flag = row.flag
        out.importance = row.importance ?? m.importance
        out.categories = row.categories ?? m.categories
        return out
    }

    /// 목록의 다음 두 통과 이전 한 통을 미리 받아 둔다 (본문, 그림이 있으면 첨부 목록).
    /// 서버 한도를 넘지 않게: 한 번에 한 통씩 차례로, 다른 요청이 몰려 있거나 최근에 막혔으면(2분) 쉰다.
    func prefetchNeighbors(of id: String) {
        // 설정 > 일반 > 미리 받기
        guard Prefs.bool(Prefs.prefetch, true), GraphThrottle.isCalm else { return }
        let order = navigationOrder
        guard let i = order.firstIndex(of: id) else { return }
        let neighbors = [i + 1, i + 2, i - 1].filter { order.indices.contains($0) }.map { order[$0] }
            .filter { detailCache.get($0) == nil && !detailCache.inFlight.contains($0) }
        guard !neighbors.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task(priority: .utility) { [weak self] in
            for next in neighbors {
                guard let self, !Task.isCancelled, GraphThrottle.isCalm else { return }
                // 사용자가 연 메일의 요청이 먼저: 관문이 바쁘면 잠깐 기다린다.
                var waited = 0
                while GraphMailService.gate.isBusy && waited < 20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                guard !Task.isCancelled, self.detailCache.get(next) == nil, self.detailCache.begin(next) else { continue }
                defer { self.detailCache.end(next) }
                guard let m = try? await self.service.message(id: next) else { return }
                var attachments: [FileAttachment]? = Self.needsAttachments(m) ? nil : []
                if m.body?.content.contains("cid:") ?? false {
                    attachments = try? await self.service.attachments(messageID: next)
                }
                self.detailCache.put(next, DetailCache.Entry(message: m, attachments: attachments))
            }
        }
    }
}
