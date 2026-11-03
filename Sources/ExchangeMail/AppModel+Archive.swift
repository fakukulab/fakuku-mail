import AppKit
import ExchangeMailKit
import Foundation
import UniformTypeIdentifiers

// S-053 메일상자 내보내기: 서버 폴더의 메일 원본을 내 Mac의 .mbox 파일 하나로 보관한다.
// 맥 Mail(파일 > 메일상자 가져오기), Thunderbird가 읽고, FAKUKU Mail의 "메일상자 가져오기…"로도 본다.

extension AppModel {
    /// 메일상자 > 메일상자 내보내기… : 고른 폴더를 저장할 곳을 묻고 내보내기 시작
    func exportSelectedMailbox() {
        guard !archiveExporting, let folder = selectedFolder else { return }
        let panel = NSSavePanel()
        panel.title = L("메일상자 내보내기")
        panel.message = L("\"\(folder.displayName)\"의 메일 \(folder.totalItemCount ?? 0)통을 mbox 파일 하나로 저장합니다.")
        panel.prompt = L("내보내기")
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "\(folder.displayName) \(day).mbox"
        panel.allowedContentTypes = [Self.mboxType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportTask = Task { [weak self] in
            guard let self else { return }
            if let done = await self.exportMailbox(folder, to: url) {
                self.noticeMessage = L("\"\(folder.displayName)\"의 메일 \(done.saved)통을 내보냈습니다.")
                    + (done.failed > 0 ? L(" \(done.failed)통은 원본을 받지 못해 빠졌습니다.") : "")
                    + "\n\(url.path)"
                if !SelfTest.requested { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    /// 내보내기 중단 (만들던 파일은 지운다)
    func cancelExport() {
        exportTask?.cancel()
    }

    static let mboxType = UTType(filenameExtension: "mbox") ?? .data
    static let emlType = UTType(filenameExtension: "eml") ?? .data

    /// 폴더의 모든 메일을 받아 mbox로 쓴다. 중단되거나 쓰지 못하면 nil (만들던 파일은 지운다).
    func exportMailbox(_ folder: MailFolder, to url: URL) async -> (saved: Int, failed: Int)? {
        archiveExporting = true
        progressText = L("\"\(folder.displayName)\" 내보내는 중…")
        defer {
            archiveExporting = false
            progressText = nil
            exportTask = nil
        }
        let total = folder.totalItemCount ?? 0
        var saved = 0
        var failed = 0
        do {
            // 다른 곳에 써 두었다가 끝나면 옮긴다: 중간에 멈춰도 반쪽 파일이 남지 않게.
            let partial = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).part")
            try? FileManager.default.removeItem(at: partial)
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            do {
                // 오래된 메일부터 쓴다 (mbox의 보통 순서).
                var page = try await service.messages(folderID: folder.id, search: nil, filter: nil, oldestFirst: true)
                while true {
                    for m in page.messages {
                        try Task.checkCancellation()
                        if let mime = await mimeWithRetry(m.id) {
                            try handle.write(contentsOf: MailArchive.mboxEntry(mime, date: m.receivedDateTime))
                            saved += 1
                        } else {
                            failed += 1
                        }
                        progressText = L("\"\(folder.displayName)\" 내보내는 중… \(saved + failed)") + (total > 0 ? L(" / \(total)통") : L("통"))
                    }
                    guard let next = page.nextLink else { break }
                    page = try await service.nextPage(next)
                }
                try handle.close()
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: partial, to: url)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
            return (saved, failed)
        } catch is CancellationError {
            noticeMessage = L("내보내기를 중단했습니다.")
            return nil
        } catch {
            report(error, quietIfOffline: false)
            return nil
        }
    }

    /// 원본 하나. Exchange가 잠시 막으면(429, 503) 쉬었다가 한 번 더.
    private func mimeWithRetry(_ id: String) async -> Data? {
        do {
            return try await service.mimeContent(id: id)
        } catch let error as GraphError where error.status == 429 || error.status == 503 {
            try? await Task.sleep(for: .seconds(30))
            return try? await service.mimeContent(id: id)
        } catch {
            return nil
        }
    }

    // MARK: 메일 파일 열기

    /// 파일 > 메일상자 가져오기… : .mbox, .eml (맥 Mail이 내보낸 .mbox 폴더도)
    static func chooseArchive() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("메일상자 가져오기")
        panel.message = L("mbox 파일, 맥 Mail이 내보낸 .mbox 폴더, eml 파일을 고르세요.")
        panel.prompt = L("가져오기")
        panel.allowedContentTypes = [mboxType, emlType, UTType(filenameExtension: "emlx") ?? .data, .emailMessage]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// 보관 파일 읽기 (메인 스레드 밖에서)
nonisolated enum ArchiveFile {
    /// 파일 하나(.mbox, .eml, .emlx) 또는 폴더.
    /// 맥 Mail이 내보낸 .mbox는 폴더이고 안의 "mbox" 파일에 메일이 있다.
    /// 그 파일이 없는 폴더(맥 Mail 저장소의 .mbox, eml 모음)는 안의 .emlx·.eml을 모두 읽는다.
    static func load(_ url: URL) throws -> [ArchivedMail] {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { return MailArchive.read(messages: try messages(in: url)) }
        let mbox = url.appending(path: "mbox")
        if FileManager.default.fileExists(atPath: mbox.path) {
            return MailArchive.read(try Data(contentsOf: mbox, options: .mappedIfSafe))
        }
        var all: [Data] = []
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard ["emlx", "eml", "mbox"].contains(file.pathExtension.lowercased()) else { continue }
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &dir)
            if !dir.boolValue { all += (try? messages(in: file)) ?? [] }
        }
        return MailArchive.read(messages: all)
    }

    /// 파일 하나의 메일 원본들
    private static func messages(in file: URL) throws -> [Data] {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        if file.pathExtension.lowercased() == "emlx" { return [MailArchive.emlxMessage(data)] }
        return MailArchive.split(data)
    }
}
