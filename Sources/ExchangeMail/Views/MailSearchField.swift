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
            TextField("검색", text: $model.searchText, prompt: Text("검색"))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { Task { await model.loadMessages() } }
                .onExitCommand {
                    model.searchText = ""
                    focused = false
                }
            if !model.searchText.isEmpty {
                Button("검색어 지우기", systemImage: "xmark.circle.fill") { model.searchText = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            // 검색 범위 (S-033)
            Picker("검색 범위", selection: $model.searchScope) {
                Text("이 폴더").tag(SearchScope.folder)
                Text("모든 폴더").tag(SearchScope.all)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("검색 범위")
        }
        .padding(.leading, Space.sm)
        .frame(width: 280)
        .help("메일 검색 (⌥⌘F). Return으로 찾고 Esc로 지웁니다.")
        .onChange(of: model.searchFocusRequest) { _, _ in focused = true }
    }
}
