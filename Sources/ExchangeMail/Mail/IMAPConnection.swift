import ExchangeMailKit
import Foundation

// M24 IMAP 연결 하나: TLS(993)로 붙고, 명령을 차례대로 보내고, 응답을 읽는다.
// 외부 패키지 없이 URLSessionStreamTask를 쓴다. 응답 해석은 Kit의 `IMAP`.

nonisolated enum IMAPError: Error, LocalizedError {
    /// 서버가 NO/BAD로 답했다
    case server(String)
    /// 로그인 실패 (암호가 틀림)
    case login(String)
    /// 연결이 끊겼다
    case closed
    /// 이 계정 종류에서는 아직 할 수 없다
    case unsupported
    /// 서버에 그 종류의 폴더가 없다 (예: 보관 폴더가 없는 계정)
    case missingFolder(String)

    var errorDescription: String? {
        switch self {
        case .server(let text): L("메일 서버 오류: \(text)")
        case .login(let text): L("로그인하지 못했습니다. 이메일 주소와 앱 암호를 확인하세요. (\(text))")
        case .closed: L("메일 서버와의 연결이 끊겼습니다.")
        case .unsupported: L("이 계정에서는 아직 할 수 없는 기능입니다.")
        case .missingFolder(let kind): L("이 계정의 메일 서버에 \(IMAPError.folderName(kind)) 폴더가 없습니다.")
        }
    }

    static func folderName(_ kind: String) -> String {
        switch kind {
        case "deleteditems": L("휴지통")
        case "archive": L("보관")
        case "junkemail": L("정크 메일")
        case "sentitems": L("보낸 편지함")
        case "drafts": L("임시 보관함")
        default: kind
        }
    }
}

/// 명령 한 줄의 조각: 글자, 또는 {n} 덩어리 (서버가 "+"로 답한 뒤 보낸다)
nonisolated enum IMAPPart: Sendable {
    case text(String)
    case literal(Data)
}

/// SELECT 결과와 명령의 응답들
nonisolated struct IMAPReply: Sendable {
    /// 서버가 보낸 "* …" 응답들
    var untagged: [[IMAPValue]]
    /// 끝 줄의 글 (예: "[COPYUID 1 5 9] Done")
    var text: String
}

actor IMAPConnection {
    let host: String
    let port: Int
    private let username: String
    private let password: String

    private var task: URLSessionStreamTask?
    private var buffer = Data()
    /// 버퍼에서 아직 읽지 않은 첫 바이트
    private var start = 0
    /// 다시 훑기 전에 버퍼가 가져야 할 크기
    private var needed = 0
    private var counter = 0
    /// 지금 고른 폴더 (같은 폴더면 SELECT를 다시 하지 않는다)
    private var selected: String?
    private var selectedExists = 0

    // 명령은 한 번에 하나: 앞 명령이 끝날 때까지 기다린다
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    // MARK: 차례 지키기

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// 폴더를 고르고(`path`가 있으면) 명령 하나를 보낸다. 연결이 끊겼으면 한 번 다시 붙는다.
    func run(select path: String? = nil, _ parts: [IMAPPart]) async throws -> IMAPReply {
        await acquire()
        defer { release() }
        do {
            return try await runLocked(select: path, parts)
        } catch IMAPError.closed {
            disconnect()
            return try await runLocked(select: path, parts)
        } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
            // 잠든 사이 서버가 끊은 연결: 다시 붙어 본다. 그래도 안 되면 오류 (오프라인 캐시가 받는다)
            disconnect()
            return try await runLocked(select: path, parts)
        }
    }

    func run(select path: String? = nil, _ command: String) async throws -> IMAPReply {
        try await run(select: path, [.text(command)])
    }

    /// 폴더의 최근 메일 `count`통. 폴더를 늘 새로 연다(SELECT): iCloud는 열어 둔 폴더에 다른 연결이 넣은 메일
    /// (보낸 편지함 사본, 새 메일)을 NOOP로는 늦게 알려 준다. 돌려주는 `low`는 받은 가장 오래된 순번.
    func latest(in path: String, count: Int, items: String) async throws -> (low: Int, reply: IMAPReply) {
        if selected == path { selected = nil }
        _ = try await run(select: path, [])
        let top = selectedExists
        guard top > 0 else { return (1, IMAPReply(untagged: [], text: "")) }
        let low = max(1, top - count + 1)
        return (low, try await run(select: path, "FETCH \(low):\(top) (\(items))"))
    }

    private func runLocked(select path: String?, _ parts: [IMAPPart]) async throws -> IMAPReply {
        try await connectIfNeeded()
        if let path, path != selected {
            let reply = try await send([.text("SELECT " + IMAP.quote(IMAP.encodeFolderName(path)))])
            selected = path
            selectedExists = reply.untagged.first { $0.count >= 2 && $0[1].text?.uppercased() == "EXISTS" }?[0].int ?? 0
        }
        guard !parts.isEmpty else { return IMAPReply(untagged: [], text: "") }
        let reply = try await send(parts)
        // 고른 폴더의 수가 바뀌면(새 메일, 지우기) 따라간다
        if path != nil, let n = reply.untagged.last(where: { $0.count >= 2 && $0[1].text?.uppercased() == "EXISTS" })?[0].int {
            selectedExists = n
        }
        return reply
    }

    // MARK: 연결

    /// 연결하고 로그인한다 (계정 추가 때 암호 확인에도 쓴다)
    func connectIfNeeded() async throws {
        guard task == nil else { return }
        let t = URLSession.shared.streamTask(withHostName: host, port: port)
        t.resume()
        t.startSecureConnection()
        task = t
        buffer = Data()
        start = 0
        needed = 0
        selected = nil
        do {
            // 인사말 "* OK …"
            guard case .untagged(let hello) = try await readResponse(), hello.first?.text?.uppercased() == "OK" else {
                throw IMAPError.closed
            }
            do {
                _ = try await send([.text("LOGIN "), .literalOrQuoted(username), .text(" "), .literalOrQuoted(password)])
            } catch IMAPError.server(let text) {
                throw IMAPError.login(text)
            }
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        selected = nil
        buffer = Data()
        start = 0
        needed = 0
    }

    func logout() async {
        if task != nil { _ = try? await send([.text("LOGOUT")]) }
        disconnect()
    }

    // MARK: 보내고 읽기

    private func nextTag() -> String {
        counter += 1
        return "F\(counter)"
    }

    private func send(_ parts: [IMAPPart]) async throws -> IMAPReply {
        guard let task else { throw IMAPError.closed }
        let tag = nextTag()
        var line = Data((tag + " ").utf8)
        var untagged: [[IMAPValue]] = []
        for part in parts {
            switch part {
            case .text(let s):
                line.append(Data(s.utf8))
            case .literal(let data):
                // {n} 을 보내고 서버의 "+" 를 기다린 뒤 덩어리를 보낸다
                line.append(Data("{\(data.count)}\r\n".utf8))
                try await task.write(line, timeout: 60)
                line = Data()
                waitPlus: while true {
                    switch try await readResponse() {
                    case .continuation: break waitPlus
                    case .untagged(let v): untagged.append(v)
                    case .tagged(_, let status, let text):
                        throw status == "OK" ? IMAPError.closed : IMAPError.server(text)
                    }
                }
                line = data
            }
        }
        line.append(Data("\r\n".utf8))
        try await task.write(line, timeout: 60)
        while true {
            switch try await readResponse() {
            case .untagged(let v):
                untagged.append(v)
                if v.first?.text?.uppercased() == "BYE" { disconnect(); throw IMAPError.closed }
            case .continuation:
                continue
            case .tagged(let t, let status, let text):
                guard t == tag else { continue }
                guard status == "OK" else { throw IMAPError.server(text) }
                return IMAPReply(untagged: untagged, text: text)
            }
        }
    }

    private func readResponse() async throws -> IMAPResponse {
        while true {
            // 버퍼가 필요한 크기가 되기 전에는 다시 훑지 않는다 (큰 메일의 {n} 덩어리)
            if buffer.count >= needed {
                switch IMAP.scan(buffer, from: start) {
                case .complete(let end):
                    let response = buffer.subdata(in: start..<end)
                    start = end
                    needed = 0
                    // 읽은 앞부분은 가끔 한꺼번에 버린다 (응답마다 남은 버퍼를 복사하지 않게)
                    if start == buffer.count {
                        buffer.removeAll(keepingCapacity: true)
                        start = 0
                    } else if start > 1 << 20 {
                        buffer = buffer.subdata(in: start..<buffer.count)
                        start = 0
                    }
                    return IMAP.parse(response)
                case .incomplete(let n):
                    needed = n
                }
            }
            guard let task else { throw IMAPError.closed }
            let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 1 << 20, timeout: 120)
            if let data, !data.isEmpty { buffer.append(data) } else if atEOF { disconnect(); throw IMAPError.closed }
        }
    }
}

extension IMAPPart {
    /// 글자에 8비트·따옴표·줄바꿈이 있으면 {n} 덩어리, 아니면 따옴표 글
    nonisolated static func literalOrQuoted(_ s: String) -> IMAPPart {
        let plain = s.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F } && !s.contains("\"") && !s.contains("\\")
        return plain ? .text(IMAP.quote(s)) : .literal(Data(s.utf8))
    }
}
