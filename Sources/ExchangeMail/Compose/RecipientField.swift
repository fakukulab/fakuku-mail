import AppKit
import ExchangeMailKit
import SwiftUI

/// 작성 창의 받는 사람 칸 (맥 Mail처럼): 시스템 토큰 칸(NSTokenField). 끝난 주소는 이름 토큰(⌄ 메뉴)으로,
/// 쉼표·세미콜론·Return이나 자동완성으로 토큰이 되고, 토큰을 두 번 누르면 고친다.
/// 칸의 값은 예전처럼 "이름 <주소>, 주소, …" 글자 하나다 (초안·보내기는 그대로).
/// (SwiftUI로 만든 토큰 줄은 자리 계산이 AppKit 제약과 맞물려 앱이 멈췄다: docs/FIXLOG.md)
struct RecipientField<Focus: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var text: String
    let book: AddressBookStore
    var focus: FocusState<Focus?>.Binding
    let focusValue: Focus

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
        field.completionDelay = 0.1
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.setAccessibilityLabel(title)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.objectValue = Self.tokens(text)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isEditing, Self.text(of: field) != text {
            field.objectValue = Self.tokens(text)
        }
        // 작성 창이 이 칸을 고르라고 하면 (새 메일을 열 때 받는 사람)
        if focus.wrappedValue == focusValue, let window = field.window,
           field.currentEditor() == nil, !context.coordinator.isEditing {
            Task { @MainActor in window.makeFirstResponder(field) }
        }
    }

    /// 폭에 맞춰 줄 바꿈한 높이
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTokenField, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height
            ?? field.intrinsicContentSize.height
        return CGSize(width: width, height: ceil(height))
    }

    static func tokens(_ text: String) -> [String] {
        let p = AddressBook.pieces(text)
        return p.pending.isEmpty ? p.tokens : p.tokens + [p.pending]
    }

    static func text(of field: NSTokenField) -> String {
        let items = (field.objectValue as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return items.joined(separator: ", ")
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: RecipientField
        var isEditing = false

        init(_ parent: RecipientField) { self.parent = parent }

        private func push(_ field: NSTokenField) {
            let value = RecipientField.text(of: field)
            if value != parent.text { parent.text = value }
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            isEditing = true
            if parent.focus.wrappedValue != parent.focusValue { parent.focus.wrappedValue = parent.focusValue }
        }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTokenField { push(field) }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            isEditing = false
            if let field = note.object as? NSTokenField { push(field) }
            // 다른 칸(제목 등)이 이미 초점을 가져갔으면 건드리지 않는다
            if parent.focus.wrappedValue == parent.focusValue { parent.focus.wrappedValue = nil }
        }

        // MARK: 토큰 모양

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            guard let token = representedObject as? String else { return nil }
            return AddressParser.parseOne(token)?.display ?? token
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            representedObject as? String
        }

        func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
            editingString.trimmingCharacters(in: .whitespaces)
        }

        func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
            .rounded
        }

        // MARK: 자동완성 (주소록)

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let list = parent.book.suggestions(for: substring).map(\.editable)
            // 후보를 미리 고르지 않는다: 고르면 쓰던 글자가 그 후보로 채워져, 목록에 없는 주소를 넣을 수 없다
            selectedIndex?.pointee = -1
            return list
        }

        // MARK: ⌄ 메뉴

        func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool { true }

        func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject representedObject: Any) -> NSMenu? {
            guard let token = representedObject as? String else { return nil }
            menuField = tokenField
            let menu = NSMenu()
            let header = NSMenuItem(title: AddressParser.parseOne(token)?.address ?? token, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            let copy = NSMenuItem(title: L("주소 복사"), action: #selector(copyAddress(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = token
            menu.addItem(copy)
            let remove = NSMenuItem(title: L("제거"), action: #selector(removeToken(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = token
            menu.addItem(remove)
            return menu
        }

        /// 메뉴를 연 칸 (제거에 쓴다)
        private weak var menuField: NSTokenField?

        @objc private func copyAddress(_ sender: NSMenuItem) {
            guard let token = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AddressParser.parseOne(token)?.editable ?? token, forType: .string)
        }

        @objc private func removeToken(_ sender: NSMenuItem) {
            guard let field = menuField, let token = sender.representedObject as? String else { return }
            var items = field.objectValue as? [Any] ?? []
            if let i = items.firstIndex(where: { ($0 as? String) == token }) { items.remove(at: i) }
            field.objectValue = items
            push(field)
        }
    }
}
