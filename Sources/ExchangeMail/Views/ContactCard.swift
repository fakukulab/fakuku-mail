import AppKit
import ExchangeMailKit
import Contacts
import ContactsUI

/// 머리글 주소 메뉴 > 연락처 카드 보기. macOS 연락처에서 그 주소를 찾아 카드를 보이고,
/// 없으면 연락처에 추가할지 묻는다. 처음 한 번 연락처 접근 권한을 묻는다 (Info.plist의 NSContactsUsageDescription).
enum ContactCard {
    /// 열린 카드 창 (닫힐 때까지 잡아 둔다)
    private static var windows: [NSWindow] = []

    static func show(address: String, name: String?) async {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else {
            let alert = NSAlert()
            alert.messageText = L("연락처에 접근할 수 없습니다")
            alert.informativeText = L("시스템 설정 > 개인정보 보호 및 보안 > 연락처에서 FAKUKU Mail을 켜 주세요.")
            alert.addButton(withTitle: L("시스템 설정 열기"))
            alert.addButton(withTitle: L("취소"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let keys = [CNContactViewController.descriptorForRequiredKeys()]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
        if let found = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first {
            present(found, title: name ?? address)
            return
        }
        // 연락처에 없으면 추가할지 묻는다.
        let alert = NSAlert()
        alert.messageText = L("\(name.map { "\($0) <\(address)>" } ?? address)은(는) 연락처에 없습니다")
        alert.informativeText = L("연락처에 추가하면 카드를 볼 수 있고, 다른 앱에서도 이 이름으로 보입니다.")
        alert.addButton(withTitle: L("연락처에 추가"))
        alert.addButton(withTitle: L("취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let contact = newContact(address: address, name: name)
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            if let saved = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first {
                present(saved, title: name ?? address)
            }
        } catch {
            let failed = NSAlert(error: error)
            failed.runModal()
        }
    }

    /// 이름을 이름·성으로 나눈다: "Shakil Kamal" → Shakil / Kamal, 한글 "김전" → 전 / 김
    static func newContact(address: String, name: String?) -> CNMutableContact {
        let c = CNMutableContact()
        let full = (name ?? "").trimmingCharacters(in: .whitespaces)
        let words = full.split(separator: " ").map(String.init)
        if words.count >= 2 {
            c.givenName = words.dropLast().joined(separator: " ")
            c.familyName = words.last ?? ""
        } else if full.count >= 2, full.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }) {
            c.familyName = String(full.prefix(1))
            c.givenName = String(full.dropFirst())
        } else {
            c.givenName = full
        }
        c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: address as NSString)]
        return c
    }

    private static func present(_ contact: CNContact, title: String) {
        let controller = CNContactViewController()
        controller.contact = contact
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 420, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        // 닫힌 창은 놓아준다.
        windows.removeAll { !$0.isVisible }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}
