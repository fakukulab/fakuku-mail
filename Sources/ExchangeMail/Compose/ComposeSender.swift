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
        let to = AddressParser.parse(input.to)
        let cc = AddressParser.parse(input.cc)
        let bcc = AddressParser.parse(input.bcc)
        let invalid = to.invalid + cc.invalid + bcc.invalid
        guard invalid.isEmpty else { throw Problem.invalidAddresses(invalid) }
        guard !(to.valid + cc.valid + bcc.valid).isEmpty else { throw Problem.noRecipients }

        var attachments = input.extraAttachments
        for url in input.files {
            guard let data = try? Data(contentsOf: url) else { throw Problem.unreadableFile(url.lastPathComponent) }
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: mimeType(for: url), data: data))
        }

        let message = OutgoingMessage(from: input.from, to: to.valid, cc: cc.valid, bcc: bcc.valid,
                                      subject: input.subject, html: wrap(input.bodyHTML), attachments: attachments,
                                      inReplyTo: input.draft.inReplyTo, references: input.draft.references)
        let domain = input.from.address.split(separator: "@").last.map(String.init) ?? "exchangemail.local"
        let mime = MIMEBuilder.build(message, options: input.fixEnabled ? options : .off,
                                     messageID: "\(UUID().uuidString)@\(domain)", date: date)
        let requestSize = MIMEBuilder.graphRequestSize(forMIMEBytes: mime.count)
        guard requestSize <= MIMEBuilder.graphRequestLimit else { throw Problem.tooLarge(requestSize) }
        return mime
    }
}
