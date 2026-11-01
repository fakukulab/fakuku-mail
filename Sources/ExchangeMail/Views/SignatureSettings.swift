import ExchangeMailKit
import SwiftUI

/// 설정 > 서명: 서명 목록, 편집기, 상황별 기본 서명 (S-009, S-010).
struct SignatureSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var editor = RichTextController()
    @State private var showSource = false
    @State private var source = ""
    /// 편집기에 지금 들어 있는 서명. 사람이 고친 내용은 이 서명에만 저장한다.
    @State private var loadedID: UUID?

    private var store: SignatureStore { model.signatures }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
            editorPane
                .frame(minWidth: 480)
        }
        .onAppear {
            if selection == nil { selection = store.signatures.first?.id }
            editor.onUserEdit = { html in
                if let id = loadedID { store.update(id: id, html: html) }
            }
            load()
        }
        .onChange(of: selection) { _, _ in
            showSource = false
            load()
        }
        .onChange(of: showSource) { _, on in
            if on {
                source = store.signature(id: selection)?.html ?? ""
            } else {
                load(force: true)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.signatures) { s in
                    Text(s.name).tag(s.id)
                }
            }
            .overlay {
                if store.signatures.isEmpty {
                    ContentUnavailableView("서명 없음", systemImage: "signature",
                                           description: Text("+ 버튼으로 서명을 추가하세요."))
                }
            }
            HStack(spacing: 0) {
                Button("서명 추가", systemImage: "plus") { selection = store.add().id }
                    .help("서명 추가")
                Button("서명 삭제", systemImage: "minus") { deleteSelected() }
                    .help("서명 삭제")
                    .disabled(selection == nil)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(Space.sm)
            Divider()
            rules
                .padding(Space.md)
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("기본 서명")
                .font(.headline)
            ForEach(ComposeKind.ruleKinds) { kind in
                Picker(kind.ruleLabel, selection: Binding(
                    get: { store.ruleSelection(kind) },
                    set: { store.setRule(kind, to: $0) })) {
                    Text("없음").tag(UUID?.none)
                    ForEach(store.signatures) { s in
                        Text(s.name).tag(UUID?.some(s.id))
                    }
                }
            }
            Text("작성 창에서 언제든 다른 서명으로 바꿀 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let id = selection, let signature = store.signature(id: id) {
            VStack(spacing: 0) {
                HStack(spacing: Space.sm) {
                    TextField("서명 이름", text: Binding(
                        get: { signature.name },
                        set: { store.update(id: id, name: $0) }))
                        .textFieldStyle(.roundedBorder)
                    Toggle("HTML 소스", isOn: $showSource)
                        .toggleStyle(.button)
                        .help("HTML을 직접 고칩니다")
                }
                .padding(Space.md)
                Divider()
                if showSource {
                    TextEditor(text: $source)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: source) { _, text in store.update(id: id, html: text) }
                } else {
                    FormatToolbar(controller: editor)
                    Divider()
                    RichTextEditor(controller: editor)
                        // 서명에 그림 파일을 끌어다 놓으면 본문에 넣는다.
                        .dropDestination(for: URL.self) { urls, _ in
                            editor.dropped(urls.filter(\.isFileURL))
                            return true
                        }
                }
            }
        } else {
            ContentUnavailableView("서명을 고르세요", systemImage: "signature",
                                   description: Text("왼쪽에서 서명을 고르거나 새로 추가하세요."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load(force: Bool = false) {
        guard let id = selection, let s = store.signature(id: id) else {
            loadedID = nil
            return
        }
        if loadedID == id && !force { return }
        // setHTML은 사람이 고친 것으로 치지 않으므로 onUserEdit가 다른 서명에 쓰지 않는다.
        loadedID = id
        editor.setHTML(s.html)
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        let index = store.signatures.firstIndex { $0.id == id } ?? 0
        store.delete(id: id)
        selection = store.signatures.isEmpty ? nil : store.signatures[min(index, store.signatures.count - 1)].id
    }
}
