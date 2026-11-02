import AppKit
import ExchangeMailKit
import Foundation

/// 메일을 별도 창으로 열기 (S-043): 무엇을 열지, 그리고 목록 밖의 메일 한 통에 하는 동작.
extension AppModel {

    enum OpenTarget: Equatable {
        /// 임시 보관함의 초안은 작성 창에서 이어서 쓴다 (S-022)
        case compose(ComposeDraft)
        /// 그 밖의 메일은 메시지 창으로
        case message(String)
    }

    /// 두 번 클릭, Return, ⌘O로 열 것. 본문에 보이는 메일(대화에서 펼친 메일 포함)을 연다.
    func openTarget() -> OpenTarget? {
        if let draft = resumeDraft() { return .compose(draft) }
        guard multipleSelectionCount == 0, let id = displayedMessageID else { return nil }
        return .message(id)
    }

    /// 깃발 하나를 바꾸고 목록·대화에도 반영한다. 바꿨으면 true.
    func setFlag(id: String, flagged: Bool) async -> Bool {
        do {
            try await service.setFlag(id: id, flagged: flagged)
        } catch {
            report(error, quietIfOffline: false)
            return false
        }
        let state: FollowupFlag = flagged ? .flagged : .notFlagged
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].flag = state }
        if let t = thread.firstIndex(where: { $0.id == id }) { thread[t].flag = state }
        patchDetail(id) { $0.flag = state }
        if selectedFolderID == FolderOrder.flaggedID && !flagged {
            messages.removeAll { $0.id == id }
            selection.remove(id)
        }
        updateMenu()
        return true
    }

    /// 메시지 창의 메일을 옮긴다. 목록에 있으면 목록에서 옮기는 것과 같고(다음 줄을 고른다),
    /// 없으면(다른 폴더를 보고 있으면) 그 메일만 옮긴다. ⌘Z는 메인 창의 되돌리기에 남긴다. 옮겼으면 true.
    func moveOpened(_ message: MailMessage, to destination: String, undoName: String) async -> Bool {
        let undo = mainWindowUndoManager
        if messages.contains(where: { $0.id == message.id }) {
            await move([message.id], to: destination, undoManager: undo, undoName: undoName)
            return !messages.contains { $0.id == message.id }
        }
        let from = message.parentFolderId ?? "inbox"
        do {
            let newID = try await service.move(id: message.id, to: destination)
            let undoMoves = [UndoMove(messageID: newID, folderID: from)]
            undo?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    _ = Task { await target.restore(undoMoves) }
                }
            }
            undo?.setActionName(undoName)
            if thread.contains(where: { $0.id == message.id }) { await loadThread() }
            await loadFolders()
            return true
        } catch {
            report(error, quietIfOffline: false)
            return false
        }
    }

    /// 메시지 창이 닫혀도 ⌘Z가 남도록 메인 창의 되돌리기 관리자를 쓴다.
    private var mainWindowUndoManager: UndoManager? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.undoManager
            ?? NSApp.mainWindow?.undoManager
    }
}
