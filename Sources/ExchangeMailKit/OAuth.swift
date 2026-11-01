import CryptoKit
import Foundation
import Security

/// Microsoft identity platform OAuth2 Authorization Code + PKCE (RFC 7636). MSAL 없이 직접 구현.
public enum OAuth {
    public static let scopes = "offline_access User.Read Mail.ReadWrite Mail.Send"

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

    public static func authorizeURL(tenant: String, clientID: String, redirectURI: String,
                                    challenge: String, state: String) -> URL? {
        var c = URLComponents(string: "\(authority(tenant: tenant))/authorize")
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return c?.url
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
        case .stateMismatch: "로그인 응답이 이 요청과 맞지 않습니다. 다시 로그인하세요."
        case .missingCode: "로그인 응답에 인증 코드가 없습니다."
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
    public static let listSelect = "id,conversationId,parentFolderId,subject,from,toRecipients,receivedDateTime,bodyPreview,isRead,hasAttachments,flag"
    public static let detailSelect = "id,internetMessageId,conversationId,parentFolderId,subject,from,toRecipients,ccRecipients,bccRecipients,receivedDateTime,body,isRead,hasAttachments,internetMessageHeaders,flag"
    public static let pageSize = 50
    public static let folderSelect = "id,displayName,unreadItemCount,totalItemCount,parentFolderId,childFolderCount"

    /// 깃발 단 메일, 모든 폴더 (S-029). `$orderby`를 함께 쓰면 Graph가 거절할 수 있어 정렬은 앱에서 한다.
    public static func flagged(top: Int = pageSize) -> Request {
        Request(query: ["$filter": "flag/flagStatus eq 'flagged'", "$select": listSelect, "$top": "\(top)"], headers: [:])
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
        var q = ["$top": "\(top)", "$select": listSelect]
        var h: [String: String] = [:]
        if let s = search?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            q["$search"] = "\"\(s.replacingOccurrences(of: "\"", with: ""))\""
            h["ConsistencyLevel"] = "eventual"
        } else {
            q["$orderby"] = "receivedDateTime desc"
        }
        return Request(query: q, headers: h)
    }
}
