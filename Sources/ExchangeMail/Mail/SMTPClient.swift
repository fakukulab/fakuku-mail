import ExchangeMailKit
import Foundation

// M24 2단계: iCloud·Gmail로 보내기 (SMTP). 보낼 때마다 연결하고, 다 보내면 끊는다.
// iCloud: smtp.mail.me.com:587 (STARTTLS), Gmail: smtp.gmail.com:465 (처음부터 TLS). 로그인은 AUTH PLAIN + 앱 암호.

nonisolated enum SMTPError: Error, LocalizedError {
    case rejected(String)
    case login(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .rejected(let text): L("보내는 메일 서버가 거부했습니다: \(text)")
        case .login(let text): L("보내는 메일 서버에 로그인하지 못했습니다. 앱 암호를 확인하세요. (\(text))")
        case .closed: L("보내는 메일 서버와의 연결이 끊겼습니다.")
        }
    }
}

actor SMTPClient {
    private let host: String
    private let port: Int
    private let startTLS: Bool
    private let username: String
    private let password: String

    private var task: URLSessionStreamTask?
    private var buffer = Data()

    init(config: IMAPAccountConfig, password: String) {
        host = config.smtpHost
        port = config.smtpPort
        startTLS = config.smtpStartTLS
        // SMTP 로그인은 전체 주소 (iCloud 안내: IMAP은 @ 앞만 써도 되지만 SMTP는 주소 전체)
        username = config.email
        self.password = password
    }

    /// MIME 하나를 보낸다. 받는 사람은 MIME의 To, Cc, Bcc. 숨은 참조 머리글은 빼고 보낸다.
    func send(_ mime: Data, from: String) async throws {
        let envelope = SMTP.envelope(mime)
        guard !envelope.recipients.isEmpty else { throw SMTPError.rejected(L("받는 사람이 없습니다.")) }
        defer { close() }
        try await connect()
        try await command("MAIL FROM:<\(from)>", expect: [250])
        for address in envelope.recipients {
            try await command("RCPT TO:<\(address)>", expect: [250, 251])
        }
        try await command("DATA", expect: [354])
        guard let task else { throw SMTPError.closed }
        try await task.writeOnce(SMTP.dataPayload(SMTP.removingBcc(mime)), timeout: 300)
        try check(try await readReply(timeout: 300), expect: [250])
        _ = try? await command("QUIT", expect: [221])
    }

    /// 계정 추가 때 앱 암호 확인에도 쓸 수 있다
    func verify() async throws {
        defer { close() }
        try await connect()
        _ = try? await command("QUIT", expect: [221])
    }

    // MARK: 연결과 로그인

    private func connect() async throws {
        let t = URLSession.shared.streamTask(withHostName: host, port: port)
        t.resume()
        if !startTLS { t.startSecureConnection() }
        task = t
        buffer = Data()
        try check(try await readReply(), expect: [220])
        try await command("EHLO fakukumail.local", expect: [250])  // l10n: data
        if startTLS {
            try await command("STARTTLS", expect: [220])
            t.startSecureConnection()
            buffer = Data()
            try await command("EHLO fakukumail.local", expect: [250])  // l10n: data
        }
        do {
            try await command("AUTH PLAIN " + SMTP.plainAuth(user: username, password: password), expect: [235])
        } catch SMTPError.rejected(let text) {
            throw SMTPError.login(text)
        }
    }

    private func close() {
        task?.cancel()
        task = nil
        buffer = Data()
    }

    // MARK: 명령과 응답

    @discardableResult
    private func command(_ line: String, expect codes: Set<Int>) async throws -> SMTP.Reply {
        guard let task else { throw SMTPError.closed }
        try await task.writeOnce(Data((line + "\r\n").utf8), timeout: 60)
        let reply = try await readReply()
        try check(reply, expect: codes)
        return reply
    }

    private func check(_ reply: SMTP.Reply, expect codes: Set<Int>) throws {
        guard codes.contains(reply.code) else { throw SMTPError.rejected("\(reply.code) \(reply.text)") }
    }

    private func readReply(timeout: TimeInterval = 60) async throws -> SMTP.Reply {
        var lines: [String] = []
        while true {
            while let lf = buffer.firstIndex(of: 10) {
                var lineData = buffer[buffer.startIndex..<lf]
                if lineData.last == 13 { lineData = lineData.dropLast() }
                lines.append(String(decoding: lineData, as: UTF8.self))
                buffer = Data(buffer[(lf + 1)...])
                if let reply = SMTP.reply(from: lines) { return reply }
            }
            guard let task else { throw SMTPError.closed }
            let (data, atEOF) = try await task.readOnce(ofMinLength: 1, maxLength: 64 * 1024, timeout: timeout)
            if let data, !data.isEmpty { buffer.append(data) } else if atEOF { throw SMTPError.closed }
        }
    }
}
