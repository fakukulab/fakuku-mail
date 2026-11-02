import AppKit
import ExchangeMailKit
import SwiftUI

/// 본문 열 도구 막대 오른쪽의 검색 칸 (S-014, S-033).
/// 시스템 `.searchable` 대신 직접 만든 칸이다: 사용자화 시트에서도 안전하게 그려지고, 검색 범위가 한 번만 보인다.
/// 모델은 환경이 아니라 직접 받는다 (사용자화 시트는 항목을 창의 환경 밖에서 그린다).
struct MailSearchField: View {
    let model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("검색"), text: $model.searchText, prompt: Text(L("검색")))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { Task { await model.loadMessages() } }
                .onExitCommand {
                    model.searchText = ""
                    focused = false
                }
            if !model.searchText.isEmpty {
                Button(L("검색어 지우기"), systemImage: "xmark.circle.fill") { model.searchText = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            // 검색 범위 (S-033)
            Picker(L("검색 범위"), selection: $model.searchScope) {
                Text(L("이 폴더")).tag(SearchScope.folder)
                Text(L("모든 폴더")).tag(SearchScope.all)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(L("검색 범위"))
        }
        .padding(.leading, Space.sm)
        .frame(width: 280)
        .help(L("메일 검색 (⌥⌘F). Return으로 찾고 Esc로 지웁니다."))
        .onChange(of: model.searchFocusRequest) { _, _ in focused = true }
    }
}

/// 메일상자 > 메일 검색(⌥⌘F): 메인 창 도구 막대의 검색 칸에 초점을 준다.
/// 도구 막대 항목은 창 본문과 다른 곳에 그려져 SwiftUI `@FocusState`가 닿지 않을 때가 있어, AppKit에서 칸을 찾아 직접 준다.
enum SearchFieldFocus {
    static let placeholder = L("검색")

    @discardableResult
    static func focus() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
                ?? NSApp.mainWindow else { return false }
        window.makeKeyAndOrderFront(nil)
        // 도구 막대 항목의 보기, 그다음 창 테두리 전체(도구 막대가 그려지는 곳)를 뒤진다.
        let roots = (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView?.superview].compactMap { $0 }
        for root in roots {
            if let field = find(in: root) {
                window.makeFirstResponder(field)
                return true
            }
        }
        return false
    }

    private static func find(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable,
           field.placeholderString == placeholder || field.placeholderAttributedString?.string == placeholder {
            return field
        }
        for sub in view.subviews {
            if let field = find(in: sub) { return field }
        }
        return nil
    }
}
