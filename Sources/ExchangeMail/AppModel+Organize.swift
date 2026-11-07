import AppKit
import ExchangeMailKit
import Foundation

/// 메일 정리 (M9): 여러 통 선택, 이동, 깃발, 정크, 폴더 관리.
extension AppModel {

    // MARK: 선택 (S-027)

    /// 동작할 메일 id. 여러 줄이면 고른 줄 모두, 대화별이면 이 폴더의 그 대화 전체. 목록 순서대로.
    var selectedIDs: [String] {
        let rows: [String]
        if selection.count > 1 {
            rows = navigationOrder.filter { selection.contains($0) }
        } else if let id = selection.first ?? selectedMessageID {
            // 한 줄: 목록 선택이 먼저다 (selectedMessageID는 다음 차례에 따라온다)
            rows = [id]
        } else {
            rows = []
        }
        return expandRows(rows)
    }

    /// 줄 id → 동작할 메일 id (대화별이면 이 폴더의 그 대화 전체), 겹치지 않게 순서대로.
    /// 1.0.2: 목록을 한 번만 훑는다. 예전에는 줄마다 목록 전체를 훑고(대화 찾기) 결과 배열도 매번 처음부터 찾아,
    /// 수백 통을 고르면 수억 번 계산해 앱이 멈췄다.
    func expandRows<S: Sequence>(_ rows: S) -> [String] where S.Element == String {
        var out: [String] = []
        var seen = Set<String>()
        guard Self.organizeByConversation else {
            for row in rows where seen.insert(row).inserted { out.append(row) }
            return out
        }
        var conversationOf: [String: String] = [:]
        var members: [String: [String]] = [:]
        for m in messages {
            guard let c = m.conversationId, !c.isEmpty else { continue }
            conversationOf[m.id] = c
            members[c, default: []].append(m.id)
        }
        for row in rows {
            for id in conversationOf[row].flatMap({ members[$0] }) ?? [row] where seen.insert(id).inserted {
                out.append(id)
            }
        }
        return out
    }

    /// 고른 메일 (목록 순서). 예전 `messages.filter { selectedIDs.contains($0.id) }`는 메일마다 selectedIDs를 다시 계산했다.
    var selectedMessages: [MailMessage] {
        let ids = Set(selectedIDs)
        guard !ids.isEmpty else { return [] }
        return messages.filter { ids.contains($0.id) }
    }

    /// 여러 줄을 골랐을 때 본문 자리에 보일 수
    var multipleSelectionCount: Int { selection.count > 1 ? selection.count : 0 }

    // MARK: 이동 (S-028)

    /// "이동" 메뉴에 보일 폴더: 지금 폴더와 깃발 모아 보기는 뺀다. 하위 폴더는 들여 쓴 이름.
    var moveTargets: [MoveTarget] {
        folders.filter { $0.id != selectedFolderID }.map { f in
            MoveTarget(id: f.id, title: String(repeating: "    ", count: f.depth ?? 0) + f.displayName)
        }
    }

    /// 끌어다 놓은 줄들 (줄 id를 줄바꿈으로 이은 글자). 대화 줄이면 그 대화 전체.
    func dropped(_ payloads: [String], onto folderID: String, undoManager: UndoManager?) async {
        let rows = payloads.flatMap { $0.split(separator: "\n").map(String.init) }
        guard !rows.isEmpty, folderID != selectedFolderID, folderID != FolderOrder.flaggedID else { return }
        let ids = expandRows(rows)
        await move(ids, to: folderID, undoManager: undoManager, undoName: L("이동"))
    }

    /// 줄을 끌 때 실을 글자: 그 줄이 여러 줄 선택에 들어 있으면 고른 줄 모두.
    func dragPayload(for rowID: String) -> String {
        selection.count > 1 && selection.contains(rowID)
            ? navigationOrder.filter { selection.contains($0) }.joined(separator: "\n")
            : rowID
    }

    // MARK: 깃발 (S-029)

    /// 고른 메일에 깃발을 모두 달거나(하나라도 없으면) 모두 뗀다.
    func toggleFlagSelected() async {
        let targets = selectedMessages
        guard !targets.isEmpty else { return }
        let flag = targets.contains { !$0.isFlagged }
        do {
            for m in targets where m.isFlagged != flag {
                try await service.setFlag(id: m.id, flagged: flag)
                if !flag { forgetFlagColor(of: m) }
                if let i = messages.firstIndex(where: { $0.id == m.id }) {
                    messages[i].flag = flag ? .flagged : .notFlagged
                }
            }
            // 깃발 모아 보기에서 뗀 메일은 목록에서 빠진다.
            if selectedFolderID == FolderOrder.flaggedID && !flag {
                messages.removeAll { !$0.isFlagged }
                selection = []
            }
            updateMenu()
        } catch {
            report(error, quietIfOffline: false)
        }
    }

    // MARK: 정크 (S-030)

    /// 정크 메일 폴더에서는 받은 편지함으로("정크 아님"), 그 밖에서는 정크 메일 폴더로.
    func toggleJunkSelected(undoManager: UndoManager?) async {
        let inJunk = selectedFolder?.kind == "junkemail"
        await moveSelected(to: inJunk ? "inbox" : "junkemail", undoManager: undoManager,
                           undoName: inJunk ? L("정크 아님") : L("정크 메일로 표시"))
    }

    // MARK: 폴더 (S-031)

    /// 새 폴더를 만들고 고른다. `parentID`가 nil이면 맨 위에.
    @discardableResult
    func createFolder(named name: String, parentID: String?) async -> MailFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do {
            let folder = try await service.createFolder(name: trimmed, parentID: parentID)
            await loadFolders()
            selectedFolderID = folder.id
            return folder
        } catch {
            report(error, quietIfOffline: false)
            return nil
        }
    }

    func renameFolder(_ folder: MailFolder, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard folder.isEditable, !trimmed.isEmpty, trimmed != folder.displayName else { return }
        do {
            try await service.renameFolder(id: folder.id, name: trimmed)
            await loadFolders()
        } catch {
            report(error, quietIfOffline: false)
        }
    }

    func deleteFolder(_ folder: MailFolder) async {
        guard folder.isEditable else { return }
        do {
            try await service.deleteFolder(id: folder.id)
            if selectedFolderID == folder.id {
                selectedFolderID = folders.first { $0.kind == "inbox" }?.id
            }
            await loadFolders()
        } catch {
            report(error, quietIfOffline: false)
        }
    }
}

/// "이동" 메뉴와 시트의 한 줄
struct MoveTarget: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 글자 한 줄을 묻는 작은 창 (폴더 이름 등). 확인을 누르면 글자, 취소면 nil.
enum TextPrompt {
    static func ask(_ title: String, message: String = "", initial: String = "", confirm: String = L("확인")) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: L("취소"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func confirm(_ title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("취소"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
