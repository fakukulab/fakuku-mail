import Foundation

/// 서명 하나. HTML로 저장해 어떤 폰트·색·이미지든 쓸 수 있다 (이미지는 data: URI).
public struct Signature: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var html: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, html: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.html = html
        self.updatedAt = updatedAt
    }
}

/// 작성 창을 여는 방식.
public enum ComposeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case new, reply, replyAll, forward

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .new: "새로운 메시지"
        case .reply: "답장"
        case .replyAll: "전체 답장"
        case .forward: "전달"
        }
    }

    /// 기본 서명 규칙에서 쓰는 종류. 전체 답장은 답장 규칙을 따른다.
    public var ruleKind: ComposeKind { self == .replyAll ? .reply : self }

    /// 설정 > 서명에 보이는 규칙 줄.
    public static let ruleKinds: [ComposeKind] = [.new, .reply, .forward]

    public var ruleLabel: String {
        switch ruleKind {
        case .new: "새 메일"
        case .reply, .replyAll: "답장"
        case .forward: "전달"
        }
    }
}

/// 상황별 기본 서명: 계정별 규칙이 전역 규칙보다 앞선다.
public struct SignatureRules: Codable, Equatable, Sendable {
    /// "서명 없음"을 일부러 고른 경우의 값
    public static let noneID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// ComposeKind.rawValue → Signature.id (noneID = 서명 없음)
    public var defaults: [String: UUID] = [:]
    /// 계정 이메일(소문자) → (ComposeKind.rawValue → Signature.id)
    public var perAccount: [String: [String: UUID]] = [:]

    public init() {}

    public func signatureID(kind: ComposeKind, account: String?) -> UUID? {
        let key = kind.ruleKind.rawValue
        if let acc = account?.lowercased(), let v = perAccount[acc]?[key] {
            return v == Self.noneID ? nil : v
        }
        if let v = defaults[key] { return v == Self.noneID ? nil : v }
        return nil
    }

    /// 설정 화면의 한 줄 값. `account`가 nil이면 모든 계정(전역) 규칙.
    public func choice(kind: ComposeKind, account: String?) -> RuleChoice {
        let key = kind.ruleKind.rawValue
        let raw: UUID?
        if let acc = account?.lowercased() {
            raw = perAccount[acc]?[key]
            if raw == nil { return .inherit }
        } else {
            raw = defaults[key]
        }
        guard let raw, raw != Self.noneID else { return .none }
        return .signature(raw)
    }

    /// 설정 화면에서 고른 값을 저장한다. 전역 규칙에는 `.inherit`가 없으므로 `.none`으로 친다.
    public mutating func setChoice(_ choice: RuleChoice, kind: ComposeKind, account: String?) {
        let key = kind.ruleKind.rawValue
        let value: UUID? = switch choice {
        case .inherit: nil
        case .none: Self.noneID
        case .signature(let id): id
        }
        if let acc = account?.lowercased() {
            var map = perAccount[acc] ?? [:]
            map[key] = value
            perAccount[acc] = map.isEmpty ? nil : map
        } else {
            defaults[key] = value ?? Self.noneID
        }
    }

    /// 지운 서명을 가리키던 규칙을 모두 지운다.
    public mutating func forget(_ id: UUID) {
        for (k, v) in defaults where v == id { defaults[k] = nil }
        for (acc, map) in perAccount {
            perAccount[acc] = map.filter { $0.value != id }
        }
    }
}

/// 기본 서명 규칙 한 줄의 값.
public enum RuleChoice: Hashable, Sendable {
    /// 계정 규칙에서만: 모든 계정 규칙을 따른다
    case inherit
    /// 서명 없음
    case none
    case signature(UUID)
}

public enum SignatureComposer {
    /// 서명 블록. `data-signature` div 안의 이미지는 보낼 때 인라인(cid)으로 남는다.
    public static func block(for sig: Signature?) -> String {
        guard let sig else { return "" }
        return "<div data-signature=\"\(sig.id.uuidString)\" class=\"signature\"><br>-- <br>\(sig.html)</div>"
    }

    /// 본문의 서명 블록을 바꾸거나 지운다. 서명이 없으면 인용문 앞(없으면 끝)에 넣는다.
    public static func replace(in body: String, with sig: Signature?) -> String {
        let ranges = HTMLProcessor.signatureRanges(in: body)
        let blockHTML = block(for: sig)
        if let first = ranges.first {
            var result = body
            for r in ranges.dropFirst().reversed() { result.removeSubrange(r) }
            result.replaceSubrange(first, with: blockHTML)
            return result
        }
        if let quote = HTMLProcessor.blockRanges(in: body, attribute: "data-quote").first {
            var result = body
            result.insert(contentsOf: blockHTML, at: quote.lowerBound)
            return result
        }
        return body + blockHTML
    }
}
