import Foundation

// Siri가 읽어 주는 글 (S-057). 짧게: 보낸 사람, 제목, 앞부분 조금.

public enum MailSpeech {
    /// 읽어 줄 본문 앞부분 길이 (글자)
    public static let previewLimit = 150

    public static func sender(_ m: MailMessage) -> String {
        let name = (m.from?.emailAddress.display ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L("보낸 사람 없음") : name
    }

    /// "김 대리님이 보낸 메일입니다. 제목은 견적 요청입니다. 안녕하세요, …"
    public static func latest(_ m: MailMessage) -> String {
        var text = L("\(sender(m))님이 보낸 메일입니다. 제목은 \(m.title)입니다.")
        let preview = (m.bodyPreview ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !preview.isEmpty {
            text += " " + (preview.count > previewLimit ? String(preview.prefix(previewLimit)) + "…" : preview)
        }
        return text
    }

    /// "읽지 않은 메일 7통. 1. 김 대리, 견적 요청. 2. … 외 2통."
    public static func unreadSummary(_ list: [MailMessage], total: Int, limit: Int = 5) -> String {
        let count = max(total, list.count)
        guard count > 0 else { return L("읽지 않은 메일이 없습니다.") }
        let shown = Array(list.prefix(limit))
        var text = L("읽지 않은 메일 \(count)통.")
        for (i, m) in shown.enumerated() {
            text += " " + L("\(i + 1). \(sender(m)), \(m.title).")
        }
        if count > shown.count { text += " " + L("외 \(count - shown.count)통.") }
        return text
    }
}
