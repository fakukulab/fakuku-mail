import AppKit
import ExchangeMailKit
import SwiftUI

/// 작성 창의 받는 사람 칸 (맥 Mail처럼): 시스템 토큰 칸(NSTokenField). 끝난 주소는 이름 토큰(⌄ 메뉴)으로,
/// 쉼표·세미콜론·Return이나 자동완성으로 토큰이 되고, 토큰을 두 번 누르면 고친다.
/// 완성된 주소 뒤에 띄어쓰기를 해도 토큰이 된다 (S-086).
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
            guard let field = note.object as? NSTokenField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                completeOnSpace(editor)
                updateSuggestions(field, editor)
            }
            push(field)
        }

        // MARK: 주소 제안 (S-087)

        private let suggestions = AddressSuggestionPanel()

        /// 지금 쓰는 항목(앞 토큰·쉼표 뒤부터 커서까지)의 범위
        private func pendingRange(_ editor: NSTextView) -> NSRange? {
            let caret = editor.selectedRange()
            guard caret.length == 0 else { return nil }
            let before = (editor.string as NSString).substring(to: caret.location)
            let start = before.lastIndex { $0 == "\u{FFFC}" || $0 == "," || $0 == ";" }
                .map { before.index(after: $0) } ?? before.startIndex
            let startUTF16 = before[..<start].utf16.count
            return NSRange(location: startUTF16, length: caret.location - startUTF16)
        }

        /// 쓰는 글자로 주소록을 찾아 칸 아래에 보인다. 맨 위 줄이 골라져 있다.
        /// 쓴 글자가 이미 완성된 주소면 그 주소를 맨 위에 두어, 목록에 없는 주소도 Return으로 그대로 넣는다.
        private func updateSuggestions(_ field: NSTokenField, _ editor: NSTextView) {
            guard let range = pendingRange(editor), let window = field.window else { suggestions.hide(); return }
            let typed = (editor.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { suggestions.hide(); return }
            var list = parent.book.suggestions(for: typed).map(\.editable)
            if AddressParser.isValid(typed), !list.isEmpty,
               AddressParser.parseOne(list[0])?.address.lowercased() != typed.lowercased() {
                list.insert(typed, at: 0)
            }
            // 쓰는 글자 바로 아래, 칸 오른쪽 끝을 넘지 않게
            var x = field.bounds.minX
            if let layout = editor.layoutManager, let container = editor.textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0), actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                x = field.convert(NSPoint(x: rect.minX + editor.textContainerOrigin.x, y: 0), from: editor).x
            }
            let width: CGFloat = 360
            x = max(field.bounds.minX, min(x - 12, field.bounds.maxX - width))
            let bottom = field.convert(NSPoint(x: x, y: field.isFlipped ? field.bounds.maxY : field.bounds.minY), to: nil)
            let anchor = window.convertPoint(toScreen: NSPoint(x: bottom.x, y: bottom.y - 4))
            suggestions.onPick = { [weak self, weak field, weak editor] picked in
                guard let self, let field, let editor else { return }
                self.insert(picked, into: field, editor)
            }
            suggestions.show(list, below: anchor, width: width, in: window)
        }

        /// 고른 주소로 쓰던 항목을 바꾸고 쉼표를 넣어 토큰으로 만든다
        private func insert(_ address: String, into field: NSTokenField, _ editor: NSTextView) {
            if editor.hasMarkedText() { editor.unmarkText() }
            suggestions.hide()
            guard let range = pendingRange(editor) else { return }
            editor.insertText(address + ",", replacementRange: range)
            push(field)
        }

        /// 목록이 떠 있을 때: ↑↓로 옮기고 Return·Tab으로 넣고 Esc로 닫는다
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard suggestions.isVisible, let field = control as? NSTokenField else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): suggestions.move(by: 1); return true
            case #selector(NSResponder.moveUp(_:)): suggestions.move(by: -1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                guard let picked = suggestions.selected else { return false }
                insert(picked, into: field, textView)
                return true
            case #selector(NSResponder.cancelOperation(_:)): suggestions.hide(); return true
            default: return false
            }
        }

        /// 완성된 주소 뒤에 띄어쓰기를 하면 쉼표를 친 것처럼 토큰으로 만든다 (S-086).
        /// 이름을 쓰는 중("김민지 ")이거나 한글을 조합하는 중이면 그대로 둔다.
        private func completeOnSpace(_ editor: NSTextView) {
            let caret = editor.selectedRange()
            guard caret.length == 0, caret.location > 0, !editor.hasMarkedText() else { return }
            let before = (editor.string as NSString).substring(to: caret.location)
            // 앞 토큰(첨부 글자 U+FFFC)이나 쉼표 뒤부터가 지금 쓰는 주소
            let start = before.lastIndex { $0 == "\u{FFFC}" || $0 == "," || $0 == ";" }
                .map { before.index(after: $0) } ?? before.startIndex
            guard AddressParser.completesOnSpace(String(before[start...])) else { return }
            editor.insertText(",", replacementRange: NSRange(location: caret.location - 1, length: 1))
        }

        func controlTextDidEndEditing(_ note: Notification) {
            isEditing = false
            suggestions.hide()
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

        // MARK: 시스템 자동완성은 쓰지 않는다 (S-087: 위의 AddressSuggestionPanel)

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            []
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
