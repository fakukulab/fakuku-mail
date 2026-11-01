import ExchangeMailKit
import Foundation
import UniformTypeIdentifiers

/// 작성 창의 입력을 보정된 MIME으로 만든다. 작성 창과 셀프 테스트가 같이 쓴다.
struct ComposeSender {
    struct Input {
        var from: MailAddress
        var to: String
        var cc: String
        var bcc: String
        var subject: String
        var bodyHTML: String
        var files: [URL]
        var extraAttachments: [OutgoingAttachment]
        var draft: ComposeDraft
        var fixEnabled: Bool
    }

    enum Problem: LocalizedError, Equatable {
        case noRecipients
        case invalidAddresses([String])
        case unreadableFile(String)
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .noRecipients: "받는 사람을 한 명 이상 넣으세요."
            case .invalidAddresses(let list): "주소 형식이 올바르지 않습니다: \(list.joined(separator: ", "))"
            case .unreadableFile(let name): "첨부 파일을 읽을 수 없습니다: \(name)"
            case .tooLarge(let bytes):
                "메일이 \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))라서 보낼 수 없습니다. Exchange는 한 번에 4MB까지 받습니다. 첨부를 줄여 주세요."
            }
        }
    }

    /// 설정 > 첨부 보정의 기본값 (UserDefaults).
    static func defaultOptions(_ defaults: UserDefaults = .standard) -> FixOptions {
        FixOptions(imagesAsAttachments: defaults.object(forKey: "fixImagesAsAttachments") as? Bool ?? true,
                   eucKRFilenames: defaults.bool(forKey: "fixEUCKR"),
                   minAttachmentBytes: defaults.integer(forKey: "fixMinKB") * 1024)
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func wrap(_ body: String) -> String {
        "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,'Apple SD Gothic Neo',sans-serif;font-size:14px\">\(body)</body></html>"
    }

    static func build(_ input: Input, options: FixOptions, date: Date = Date()) throws -> Data {
        let message = try outgoing(input, validate: true)
        return try finish(message, from: input.from, options: input.fixEnabled ? options : .off, date: date)
    }

    /// 초안 저장용 MIME (S-022). 받는 사람이 비었거나 틀려도 저장하고(읽을 수 있는 주소만 헤더에),
    /// 보정은 하지 않는다: 다시 열었을 때 그림이 본문 자리에 그대로 있어야 한다. 보낼 때 보정한다.
    static func buildDraft(_ input: Input, date: Date = Date()) throws -> Data {
        let message = try outgoing(input, validate: false)
        return try finish(message, from: input.from, options: .off, date: date)
    }

    private static func outgoing(_ input: Input, validate: Bool) throws -> OutgoingMessage {
        let to = AddressParser.parse(input.to)
        let cc = AddressParser.parse(input.cc)
        let bcc = AddressParser.parse(input.bcc)
        if validate {
            let invalid = to.invalid + cc.invalid + bcc.invalid
            guard invalid.isEmpty else { throw Problem.invalidAddresses(invalid) }
            guard !(to.valid + cc.valid + bcc.valid).isEmpty else { throw Problem.noRecipients }
        }

        var attachments = input.extraAttachments
        for url in input.files {
            guard let data = try? Data(contentsOf: url) else { throw Problem.unreadableFile(url.lastPathComponent) }
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: mimeType(for: url), data: data))
        }
        return OutgoingMessage(from: input.from, to: to.valid, cc: cc.valid, bcc: bcc.valid,
                               subject: input.subject, html: wrap(input.bodyHTML), attachments: attachments,
                               inReplyTo: input.draft.inReplyTo, references: input.draft.references)
    }

    private static func finish(_ message: OutgoingMessage, from: MailAddress, options: FixOptions, date: Date) throws -> Data {
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "exchangemail.local"
        let mime = MIMEBuilder.build(message, options: options, messageID: "\(UUID().uuidString)@\(domain)", date: date)
        let requestSize = MIMEBuilder.graphRequestSize(forMIMEBytes: mime.count)
        guard requestSize <= MIMEBuilder.graphRequestLimit else { throw Problem.tooLarge(requestSize) }
        return mime
    }
}
