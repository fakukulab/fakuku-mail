import ExchangeMailKit
import SwiftUI

/// 설정 > 서명: 왼쪽 서명 목록, 오른쪽 편집기와 기본 서명 (S-009, S-010). 맥 Mail처럼 고른 서명을 바로 고친다.
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
        HStack(alignment: .top, spacing: Space.xl) {
            sidebar
                .frame(width: 220)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: Space.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Space.sm, style: .continuous).strokeBorder(.separator))
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    /// 왼쪽: 서명 이름과 첫 줄 미리보기, 아래에 + −
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.signatures) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name.isEmpty ? L("이름 없는 서명") : s.name)
                            .lineLimit(1)
                        Text(preview(s))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, Space.xs)
                    .tag(s.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if store.signatures.isEmpty {
                    ContentUnavailableView(L("서명 없음"), systemImage: "signature",
                                           description: Text(L("+를 눌러 서명을 만드세요.")))
                }
            }
            Divider()
            HStack(spacing: 0) {
                Button(L("서명 추가"), systemImage: "plus") { selection = store.add().id }
                    .help(L("서명 추가"))
                Button(L("서명 삭제"), systemImage: "minus") { deleteSelected() }
                    .help(L("고른 서명 삭제"))
                    .disabled(selection == nil)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(Space.sm)
        }
    }

    /// 오른쪽: 이름, 서식 막대, 편집기, 그 아래 기본 서명
    @ViewBuilder
    private var editorPane: some View {
        if let id = selection, let signature = store.signature(id: id) {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    TextField(L("서명 이름"), text: Binding(
                        get: { signature.name },
                        set: { store.update(id: id, name: $0) }), prompt: Text(L("서명 이름")))
                        .textFieldStyle(.roundedBorder)
                    Toggle("HTML", isOn: $showSource)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(L("HTML 소스를 직접 고칩니다"))
                }
                VStack(spacing: 0) {
                    if showSource {
                        TextEditor(text: $source)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: source) { _, text in store.update(id: id, html: text) }
                    } else {
                        // 창이 좁아도 서식 막대가 편집기 밖으로 넘치지 않게 가로로 스크롤한다.
                        ScrollView(.horizontal) {
                            FormatToolbar(controller: editor)
                        }
                        .scrollIndicators(.never)
                        Divider()
                        RichTextEditor(controller: editor)
                            // 서명에 그림 파일을 끌어다 놓으면 본문에 넣는다.
                            .dropDestination(for: URL.self) { urls, _ in
                                editor.dropped(urls.filter(\.isFileURL))
                                return true
                            }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Space.xs).strokeBorder(.separator))
                Text(L("그림은 끌어다 놓으면 들어갑니다. 고친 내용은 바로 저장됩니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                rules
            }
        } else {
            ContentUnavailableView(L("서명을 고르세요"), systemImage: "signature",
                                   description: Text(L("왼쪽에서 서명을 고르거나 +를 눌러 만드세요.")))
        }
    }

    /// 기본 서명 (S-010): 새 메일, 답장, 전달마다 하나. 작성 창에서 언제든 바꿀 수 있다.
    private var rules: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.sm, verticalSpacing: Space.md) {
            GridRow {
                Text(L("기본 서명"))
                    .font(.headline)
                    .gridCellColumns(2)
            }
            ForEach(ComposeKind.ruleKinds) { kind in
                GridRow {
                    Text("\(kind.ruleLabel):")
                        .gridColumnAlignment(.trailing)
                    Picker(kind.ruleLabel, selection: Binding(
                        get: { store.choice(kind, account: nil) },
                        set: { choice in
                            store.setChoice(choice, kind: kind, account: nil)
                            // 예전에 계정별로 정한 값이 있으면 지운다: 이 화면이 정한 값이 그대로 쓰이게.
                            if let email = model.auth.email { store.setChoice(.inherit, kind: kind, account: email) }
                        })) {
                        Text(L("없음")).tag(RuleChoice.none)
                        if !store.signatures.isEmpty { Divider() }
                        ForEach(store.signatures) { s in
                            Text(s.name).tag(RuleChoice.signature(s.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private func preview(_ s: Signature) -> String {
        let text = HTMLProcessor.plainText(from: s.html)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return text ?? L("빈 서명")
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
