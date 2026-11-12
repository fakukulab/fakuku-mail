import Foundation
import Testing
@testable import ExchangeMailKit

// 1.0.6 차단된 보낸 사람: 앱이 보관하는 목록 (설정 > 정크 메일 > 차단됨)

@Test("입력 정리: 공백·꺾쇠·mailto·대문자, 도메인 항목, 틀린 꼴")
func blockNormalize() {
    #expect(BlockList.normalize("  Spam@Junk.Example ") == "spam@junk.example")
    #expect(BlockList.normalize("Kim <kim@ex.com>") == "kim@ex.com")
    #expect(BlockList.normalize("mailto:a@b.co") == "a@b.co")
    #expect(BlockList.normalize("@Ads.Example") == "@ads.example")
    #expect(BlockList.normalize("no-at-sign") == nil)
    #expect(BlockList.normalize("a@b") == nil)
    #expect(BlockList.normalize("a@@b.com") == nil)
    #expect(BlockList.normalize("a b@c.com") == nil)
    #expect(BlockList.normalize("") == nil)
}

@Test("맞추기: 주소는 정확히, 도메인은 하위 도메인까지, 대소문자 무시")
func blockMatches() {
    let list = BlockList(addresses: ["spam@junk.example", "@ads.example"])
    #expect(list.matches("SPAM@junk.example"))
    #expect(!list.matches("notspam@junk.example"))
    #expect(list.matches("x@ads.example") && list.matches("x@mail.ads.example"))
    #expect(!list.matches("x@badads.example") && !list.matches(nil) && !list.matches(""))
    var off = list
    off.enabled = false
    #expect(off.matches("spam@junk.example") && !off.blocks("spam@junk.example"))
}

@Test("추가·빼기: 같은 항목은 한 번, 꼴이 틀리면 넣지 않는다")
func blockAddRemove() {
    var list = BlockList()
    #expect(list.add("a@b.com") && !list.add("A@B.com") && !list.add("oops"))
    list.add("@c.com")
    #expect(list.addresses == ["a@b.com", "@c.com"])
    list.remove(["A@B.COM"])
    #expect(list.addresses == ["@c.com"])
}

@Test("지운 편지함으로 옮길 메일: 켜져 있고 옮기는 방식일 때만")
func blockToTrash() {
    let mails = [
        MailMessage(id: "1", subject: "a", from: Recipient(name: nil, address: "spam@junk.example"), receivedDateTime: nil),
        MailMessage(id: "2", subject: "b", from: Recipient(name: nil, address: "friend@ok.example"), receivedDateTime: nil),
        MailMessage(id: "3", subject: "c", from: nil, receivedDateTime: nil),
    ]
    var list = BlockList(addresses: ["spam@junk.example"], mode: .trash)
    #expect(list.toTrash(mails).map(\.id) == ["1"])
    list.mode = .keep
    #expect(list.toTrash(mails).isEmpty)
    list.mode = .trash
    list.enabled = false
    #expect(list.toTrash(mails).isEmpty)
}

@Test("서버 규칙과 비교, 예전 규칙 가져오기, 저장 형식")
func blockRuleSync() throws {
    var list = BlockList(addresses: ["a@b.com", "@c.com"], mode: .trash)
    let rule = BlockedSenders.rule(addresses: ["@c.com", "A@B.com"], mode: .trash, enabled: true)
    #expect(list.sameAsRule(rule))
    list.enabled = false
    #expect(!list.sameAsRule(rule))
    #expect(BlockList().sameAsRule(nil) && !list.sameAsRule(nil))

    var fresh = BlockList()
    fresh.adopt(BlockedSenders.rule(addresses: ["old@x.com"], mode: .trash, enabled: false))
    #expect(fresh.addresses == ["old@x.com"] && fresh.mode == .trash && !fresh.enabled)
    // 이미 목록이 있으면 방식은 그대로 두고 주소만 합친다
    var mine = BlockList(addresses: ["me@x.com"], mode: .keep)
    mine.adopt(BlockedSenders.rule(addresses: ["old@x.com", "me@x.com"], mode: .trash, enabled: true))
    #expect(mine.addresses == ["me@x.com", "old@x.com"] && mine.mode == .keep)

    let data = try JSONEncoder().encode(list)
    #expect(try JSONDecoder().decode(BlockList.self, from: data) == list)
}

// Apple 연락처의 차단 목록 (읽기만)

@Test("Apple 차단 목록: 이메일 항목만 꺼내고 정리한다, 꼴이 다르면 빈 목록")
func appleBlockListParse() throws {
    let top: [String: Any] = ["__kCMFBlockListStoreArrayKey": [
        ["__kCMFItemPhoneNumberUnformattedKey": "01012345678", "__kCMFItemTypeKey": 0],
        ["__kCMFItemEmailUnformattedKey": "Spam@Apple.Example", "__kCMFItemTypeKey": 1],
        ["__kCMFItemEmailUnformattedKey": "spam@apple.example", "__kCMFItemTypeKey": 1],
        ["__kCMFItemEmailUnformattedKey": "not an address", "__kCMFItemTypeKey": 1],
    ]]
    #expect(AppleBlockList.emails(fromTopLevel: top) == ["spam@apple.example"])
    #expect(AppleBlockList.emails(fromTopLevel: nil).isEmpty)
    #expect(AppleBlockList.emails(fromTopLevel: ["other": 1]).isEmpty)

    let data = try PropertyListSerialization.data(fromPropertyList: [AppleBlockList.topKey: top], format: .binary, options: 0)
    #expect(AppleBlockList.emails(fromPlist: data) == ["spam@apple.example"])
    #expect(AppleBlockList.emails(fromPlist: Data("x".utf8)).isEmpty)
}

@Test("Apple 항목: 함께 걸러지고, 끄면 빠지고, 앱에서는 풀 수 없고, 저장하지 않는다")
func appleBlockListInUse() throws {
    var list = BlockList(addresses: ["me@x.com"], apple: ["a@apple.example", "me@x.com"])
    #expect(list.appleInUse == ["a@apple.example"])
    #expect(list.allEntries == ["me@x.com", "a@apple.example"])
    #expect(list.blocks("A@apple.example") && list.onlyApple("a@apple.example") && !list.onlyApple("me@x.com"))

    list.remove(["a@apple.example"])
    #expect(list.matches("a@apple.example"))

    let rule = BlockedSenders.rule(addresses: list.allEntries, mode: .keep, enabled: true)
    #expect(list.sameAsRule(rule))

    list.useApple = false
    #expect(!list.matches("a@apple.example") && list.allEntries == ["me@x.com"] && !list.sameAsRule(rule))

    let decoded = try JSONDecoder().decode(BlockList.self, from: JSONEncoder().encode(list))
    #expect(decoded.apple.isEmpty && decoded.useApple == false && decoded.addresses == ["me@x.com"])
    // 예전 버전이 저장한 값(useApple 없음)은 켜짐으로 읽는다
    let old = Data(#"{"addresses":["me@x.com"],"enabled":true,"mode":"keep"}"#.utf8)
    #expect(try JSONDecoder().decode(BlockList.self, from: old).useApple)
}
