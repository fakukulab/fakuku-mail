import ExchangeMailKit
import Foundation

/// 읽음 상태를 바꾼 뒤 서버 응답이 화면을 되돌리지 않게 한다 (S-081).
/// 화면은 바로 바뀌지만(setRead), 그 사이에 떠난 새로 고침(목록, 폴더 수, 대화)은 서버가 바꾸기 전 상태를 들고 온다.
/// 예전에는 그 옛 상태가 화면을 덮어 읽은 메일이 다시 읽지 않음으로 보이고, 다음 새로 고침(2분)까지 그대로였다.
extension AppModel {

    /// 메일 한 통의 읽음 변경
    struct ReadMark {
        var read: Bool
        /// 사이드바 수를 바꾼 폴더와 바꾼 양 (-1, +1, 바뀌지 않았으면 0)
        var folder: String?
        var delta: Int
        /// 서버가 받아들인 때. nil이면 아직 보내는 중.
        var confirmedAt: Date?
    }

    /// 서버가 바꾼 뒤에도 이만큼은 서버 응답보다 이 Mac의 상태를 믿는다 (서버의 다른 부분이 따라오는 시간)
    static let readSettle: TimeInterval = 10

    /// 이 요청을 시작했을 때 서버가 아직 반영하지 않았을 수 있는 변경인가
    func isUnsettled(_ mark: ReadMark, startedAt: Date) -> Bool {
        guard let confirmed = mark.confirmedAt else { return true }
        return confirmed > startedAt.addingTimeInterval(-Self.readSettle)
    }

    /// 서버에서 받은 메일 목록에, 아직 반영되지 않았을 읽음 변경을 덮는다.
    func overlayReads(_ list: [MailMessage], startedAt: Date) -> [MailMessage] {
        guard !readMarks.isEmpty else { return list }
        var out = list
        for i in out.indices {
            guard let mark = readMarks[out[i].id], isUnsettled(mark, startedAt: startedAt) else { continue }
            out[i].isRead = mark.read
        }
        return out
    }

    func overlayReads(_ page: MessagePage, startedAt: Date) -> MessagePage {
        MessagePage(messages: overlayReads(page.messages, startedAt: startedAt), nextLink: page.nextLink,
                    serverFiltered: page.serverFiltered)
    }

    /// 서버에서 받은 폴더 목록에 아직 서버에 보내는 중인 읽음 변경을 더한다 (서버 수 + 보내는 중인 변경).
    /// 새로 온 메일은 서버 수에 들어 있어 그대로 보인다. 이 요청 사이에 서버가 받아들인 변경은 서버 수에 들었는지
    /// 알 수 없으니, 자리 잡은 뒤 폴더 수를 한 번 더 받는다. 다시 받아야 하면 true.
    func addPendingCounts(_ fresh: inout [MailFolder], startedAt: Date) -> Bool {
        var deltas: [String: Int] = [:]
        var recheck = false
        for mark in readMarks.values where mark.delta != 0 {
            guard let folder = mark.folder, isUnsettled(mark, startedAt: startedAt) else { continue }
            if mark.confirmedAt == nil { deltas[folder, default: 0] += mark.delta }
            recheck = true
        }
        for i in fresh.indices {
            guard let d = deltas[fresh[i].id], let count = fresh[i].unreadItemCount else { continue }
            fresh[i].unreadItemCount = max(0, count + d)
        }
        return recheck
    }

    /// 읽음 변경이 모두 자리 잡으면 폴더 수를 서버에서 다시 받는다 (한 번만 걸어 둔다).
    func recheckCountsWhenSettled() {
        guard folderRecheck == nil else { return }
        folderRecheck = Task { [weak self] in
            // 오래 걸려도 1분이면 그만 기다린다
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                if !self.readMarks.values.contains(where: { $0.delta != 0 && self.isUnsettled($0, startedAt: now) }) { break }
            }
            guard let self, !Task.isCancelled else { return }
            self.folderRecheck = nil
            await self.loadFolders()
        }
    }

    /// 오래된 기록을 버린다 (자리 잡은 지 5분이 지난 것)
    func pruneReadMarks() {
        let cutoff = Date().addingTimeInterval(-300)
        readMarks = readMarks.filter { $0.value.confirmedAt.map { $0 > cutoff } ?? true }
    }
}
