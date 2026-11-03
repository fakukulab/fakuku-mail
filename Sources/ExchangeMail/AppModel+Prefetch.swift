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
    func prefetchNeighbors(of id: String) {
        let order = navigationOrder
        guard let i = order.firstIndex(of: id) else { return }
        let neighbors = [i + 1, i + 2, i - 1].filter { order.indices.contains($0) }.map { order[$0] }
        for next in neighbors where detailCache.get(next) == nil && detailCache.begin(next) {
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
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
