import ExchangeMailKit
import Foundation

/// 이 Mac에 먼저 저장한 초안 (S-072). 인터넷이 없어도 쓰는 내용을 잃지 않게 작성 창이 몇 초마다 여기에 저장하고,
/// 서버의 임시 보관함에 올리면 지운다. 연결되면(폴더를 다시 읽을 때) 남은 것을 임시 보관함에 올린다.
/// `.../FAKUKUMail/pending-drafts/<작성 창 id>.json`. 로그아웃해도 지우지 않는다.
struct PendingDraft: Codable, Equatable {
    struct Upload: Codable, Equatable {
        var filename: String
        var mimeType: String
        var data: Data
    }

    /// 작성 창(ComposeDraft)의 id
    var id: UUID
    /// 저장할 계정. nil이면 지금 계정.
    var accountID: String?
    /// 서버에 이미 있는 이 메일의 초안 id. 올릴 때 이것을 바꾼다.
    var replacing: String?
    var subject: String
    var to: [MailAddress]
    var cc: [MailAddress]
    var bodyHTML: String
    /// 초안 MIME (보정 없이)
    var mime: Data
    /// Graph 한도를 넘어 따로 올릴 큰 첨부
    var uploads: [Upload]
    var savedAt: Date

    var preview: DraftPreview { DraftPreview(subject: subject, to: to, cc: cc, bodyHTML: bodyHTML) }
    var outgoingUploads: [OutgoingAttachment] {
        uploads.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
    }
}

enum PendingDrafts {
    static var directory: URL { Store.directory.appending(path: "pending-drafts", directoryHint: .isDirectory) }

    private static func url(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    /// 저장한다 (같은 작성 창이면 덮어쓴다). 실패하면 false.
    @discardableResult
    static func save(_ draft: PendingDraft) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: url(draft.id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    static func load(_ id: UUID) -> PendingDraft? {
        (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode(PendingDraft.self, from: $0) }
    }

    /// 남아 있는 것 모두, 오래된 것부터
    static func all() -> [PendingDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(PendingDraft.self, from: $0) } }
            .sorted { $0.savedAt < $1.savedAt }
    }
}

extension AppModel {
    /// 이 Mac에만 저장된 초안을 서버의 임시 보관함에 올린다 (S-072). 열려 있는 작성 창의 것은 그 창이 올린다.
    /// 오프라인이면 그대로 두었다가 다음에 다시 한다. 올린 것이 있으면 true.
    @discardableResult
    func uploadPendingDrafts() async -> Bool {
        guard !uploadingPendingDrafts else { return false }
        let pending = PendingDrafts.all().filter { !openComposeIDs.contains($0.id) }
        guard !pending.isEmpty else { return false }
        uploadingPendingDrafts = true
        defer { uploadingPendingDrafts = false }
        var uploaded = false
        for draft in pending {
            guard let account = accounts.accounts.first(where: { $0.id == draft.accountID }) ?? accounts.active else { continue }
            do {
                let id = try await account.service.saveDraft(draft.mime, preview: draft.preview, replacing: draft.replacing)
                for attachment in draft.outgoingUploads {
                    try await account.service.uploadAttachment(attachment, toMessage: id) { _ in }
                }
                // 올리는 사이 같은 창이 다시 열려 새로 저장했으면 그 파일은 남긴다
                if PendingDrafts.load(draft.id)?.savedAt == draft.savedAt { PendingDrafts.remove(draft.id) }
                uploaded = true
            } catch {
                // 오프라인이면 그만두고 다음에. 다른 오류면 이 초안만 건너뛴다 (파일은 남는다).
                if OfflineError.isOffline(error) { break }
            }
        }
        if uploaded {
            await loadFolders()
            if selectedFolder?.kind == "drafts" { await loadMessages(keepSelection: true) }
        }
        return uploaded
    }
}
