import ExchangeMailKit
import Foundation
import Observation

/// 받는 사람 자동완성 주소록 (S-018). `<Store.directory>/recipients.json`.
/// 메일을 읽을 때마다 바뀌므로 1초 모아서 저장한다.
@Observable
final class AddressBookStore {
    private(set) var book = AddressBook()
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(AddressBook.self, from: data) {
            book = saved
        }
    }

    func noteSeen(_ messages: [MailMessage], me: String?) {
        var addresses: [MailAddress] = []
        for m in messages {
            var people: [Recipient] = m.toRecipients ?? []
            people += m.ccRecipients ?? []
            if let from = m.from { people.append(from) }
            addresses += people.compactMap { $0.emailAddress.mailAddress }
        }
        guard !addresses.isEmpty else { return }
        book.noteSeen(addresses, me: me)
        scheduleSave()
    }

    func noteSent(_ addresses: [MailAddress], me: String?) {
        book.noteSent(addresses, me: me)
        scheduleSave()
    }

    func suggestions(for text: String) -> [MailAddress] {
        book.suggestions(for: text)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
