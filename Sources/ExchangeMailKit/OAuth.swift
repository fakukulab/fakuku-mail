import CryptoKit
import Foundation
import Security

/// Microsoft identity platform OAuth2 Authorization Code + PKCE (RFC 7636). MSAL 없이 직접 구현.
public enum OAuth {
    /// Calendars.ReadWrite: 회의 초대 답하기 (S-038). MailboxSettings.ReadWrite: 규칙, 자동 응답 (S-039, S-040).
    public static let scopes = "offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite MailboxSettings.ReadWrite"

    /// Azure 앱 등록의 "모바일 및 데스크톱 애플리케이션" 리디렉션 URI 스킴.
    public static func redirectScheme(bundleID: String) -> String { "msauth.\(bundleID)" }
    public static func redirectURI(bundleID: String) -> String { "\(redirectScheme(bundleID: bundleID))://auth" }

    public static func authority(tenant: String) -> String {
        let t = tenant.trimmingCharacters(in: .whitespaces)
        return "https://login.microsoftonline.com/\(t.isEmpty ? "common" : t)/oauth2/v2.0"
    }

    /// 43~128자의 code_verifier (base64url, 패딩 없음).
    public static func randomVerifier(byteCount: Int = 48) -> String {
        randomBytes(byteCount).base64URLEncoded
    }

    public static func randomState() -> String { randomBytes(16).base64URLEncoded }

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            bytes = (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) }
        }
        return Data(bytes)
    }

    /// S256 code_challenge = BASE64URL(SHA256(verifier))
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    /// `loginHint`(이메일)를 주면 Microsoft 로그인 창에 그 주소가 채워져 비밀번호부터 묻는다.
    public static func authorizeURL(tenant: String, clientID: String, redirectURI: String,
                                    challenge: String, state: String, loginHint: String? = nil) -> URL? {
        var c = URLComponents(string: "\(authority(tenant: tenant))/authorize")
        let hint = loginHint?.trimmingCharacters(in: .whitespaces) ?? ""
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ] + (hint.contains("@")
            ? [URLQueryItem(name: "login_hint", value: hint)]
            : [URLQueryItem(name: "prompt", value: "select_account")])
        return c?.url
    }

    /// 회사 관리자가 이 앱을 회사 전체에 승인하는 주소 (한 번 승인하면 직원들은 바로 로그인한다).
    public static func adminConsentURL(tenant: String, clientID: String, redirectURI: String) -> URL? {
        let t = tenant.trimmingCharacters(in: .whitespaces)
        var c = URLComponents(string: "https://login.microsoftonline.com/\(t.isEmpty || t == "common" ? "organizations" : t)/v2.0/adminconsent")
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: "https://graph.microsoft.com/.default"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        return c?.url
    }

    /// 로그인 오류가 "회사 관리자의 승인이 필요하다"는 뜻인가 (AADSTS65001, 90094, 90095 등)
    public static func needsAdminConsent(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["aadsts65001", "aadsts90094", "aadsts90095", "aadsts90099", "admin approval", "admin consent",
                "관리자 승인", "관리자의 승인"].contains { m.contains($0) }  // l10n: data (서버 오류 글과 비교)
    }

    /// 리디렉션 URL에서 code를 꺼낸다. state가 다르거나 error가 있으면 오류 문구를 돌려준다.
    public static func code(from callback: URL, expectedState: String) -> Result<String, OAuthError> {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            return .failure(.server(value("error_description") ?? error))
        }
        guard value("state") == expectedState else { return .failure(.stateMismatch) }
        guard let code = value("code"), !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    /// application/x-www-form-urlencoded 본문.
    public static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        let pairs = form.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

public enum OAuthError: Error, Equatable, LocalizedError {
    case stateMismatch
    case missingCode
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: L("로그인 응답이 이 요청과 맞지 않습니다. 다시 로그인하세요.")
        case .missingCode: L("로그인 응답에 인증 코드가 없습니다.")
        case .server(let message): message
        }
    }
}

/// 토큰 응답: `{ access_token, refresh_token, expires_in }`
public struct TokenResponse: Decodable, Sendable {
    public let access_token: String
    public let refresh_token: String?
    public let expires_in: Int
}

/// 토큰 오류 응답: `{ error, error_description }`
public struct TokenErrorResponse: Decodable, Sendable {
    public let error: String
    public let error_description: String?

    /// 리프레시 토큰이 만료·취소되어 다시 로그인해야 하는 경우.
    public var needsSignIn: Bool { ["invalid_grant", "interaction_required", "invalid_client"].contains(error) }
}

extension Data {
    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Graph 메일 요청에 쓰는 쿼리.
public enum GraphQuery {
    public static let listSelect = "id,internetMessageId,conversationId,parentFolderId,subject,from,toRecipients,ccRecipients,receivedDateTime,bodyPreview,isRead,hasAttachments,flag,importance,categories"
    public static let detailSelect = "id,internetMessageId,conversationId,parentFolderId,subject,from,toRecipients,ccRecipients,bccRecipients,receivedDateTime,body,isRead,hasAttachments,internetMessageHeaders,flag"
    public static let pageSize = 50
    public static let folderSelect = "id,displayName,unreadItemCount,totalItemCount,parentFolderId,childFolderCount"

    /// 사서함 전체 검색 (S-033). `$search`는 `$orderby`와 함께 쓸 수 없다.
    public static func searchAll(_ text: String, top: Int = pageSize) -> Request {
        let q = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        return Request(query: ["$search": "\"\(q)\"", "$select": listSelect, "$top": "\(top)"],
                       headers: ["ConsistencyLevel": "eventual"])
    }

    /// 깃발 단 메일, 모든 폴더 (S-029). `$orderby`를 함께 쓰면 Graph가 거절할 수 있어 정렬은 앱에서 한다.
    public static func flagged(top: Int = pageSize) -> Request {
        Request(query: ["$filter": "flag/flagStatus eq 'flagged'", "$select": listSelect, "$top": "\(top)"], headers: [:])
    }
    /// 스마트 메일상자 (S-046): 모든 폴더에서 최근 메일. `$filter`가 있으면 `$orderby`를 빼고 정렬은 앱에서 한다
    /// (모든 폴더 요청에 둘을 함께 쓰면 Graph가 거절할 수 있다).
    public static func collect(filter: String?, top: Int = 100) -> Request {
        var q = ["$select": listSelect, "$top": "\(top)"]
        if let filter, !filter.isEmpty { q["$filter"] = filter } else { q["$orderby"] = "receivedDateTime desc" }
        return Request(query: q, headers: [:])
    }

    /// 대화 보기의 한 줄에 필요한 값 (본문은 펼칠 때 따로 가져온다)
    public static let threadSelect = "id,conversationId,parentFolderId,subject,from,toRecipients,ccRecipients,receivedDateTime,bodyPreview,isRead,hasAttachments"

    /// 대화 전체 요청 (S-025). `$orderby`와 함께 쓰면 Graph가 거절할 수 있어 정렬은 앱에서 한다.
    public static func conversation(id: String, top: Int = 50) -> Request {
        Request(query: ["$filter": Conversations.filter(conversationID: id), "$select": threadSelect, "$top": "\(top)"],
                headers: [:])
    }

    public struct Request: Equatable, Sendable {
        public var query: [String: String]
        public var headers: [String: String]
    }

    /// 목록 요청. 검색할 때는 `$orderby`를 함께 쓸 수 없다 (Graph 제한).
    public static func messageList(search: String?, top: Int = pageSize) -> Request {
        messageList(search: search, filter: nil, oldestFirst: false, top: top)
    }

    /// 목록 요청 (S-041, S-042). 검색은 `$filter`·`$orderby`와 함께 쓸 수 없어 검색이 있으면 필터는 앱에서 건다.
    /// `$filter`와 `$orderby`를 함께 쓰면 정렬 속성이 필터 맨 앞에 있어야 하므로 날짜 조건을 앞에 둔다.
    public static func messageList(search: String?, filter: String?, oldestFirst: Bool, top: Int = pageSize) -> Request {
        var q = ["$top": "\(top)", "$select": listSelect]
        var h: [String: String] = [:]
        if let s = search?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            q["$search"] = "\"\(s.replacingOccurrences(of: "\"", with: ""))\""
            h["ConsistencyLevel"] = "eventual"
        } else {
            q["$orderby"] = oldestFirst ? "receivedDateTime asc" : "receivedDateTime desc"
            if let filter, !filter.isEmpty {
                q["$filter"] = filter.hasPrefix("receivedDateTime") ? filter : "receivedDateTime ge 1900-01-01T00:00:00Z and \(filter)"
            }
        }
        return Request(query: q, headers: h)
    }
}
