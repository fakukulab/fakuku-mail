import ExchangeMailKit
import SwiftUI

/// 목록과 머리글에서 VIP 보낸 사람 앞에 붙는 아이콘 (S-045)
struct VIPBadge: View {
    let vip: VIP

    var body: some View {
        Image(systemName: vip.symbol)
            .font(.caption)
            .foregroundStyle(.tint)
            .help("VIP: \(vip.title)")
            .accessibilityLabel("VIP \(vip.title)")
    }
}

/// 아이콘 고르기: SF Symbol 격자 (VIP, 스마트 메일상자)
struct SymbolPicker: View {
    @Binding var symbol: String

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: Space.xs), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.xs) {
            ForEach(MailboxSymbols.all, id: \.self) { name in
                Button {
                    symbol = name
                } label: {
                    Image(systemName: name)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(symbol == name ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.secondary))
                        .background(symbol == name ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: Space.sm, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(symbol == name ? .isSelected : [])
            }
        }
    }
}

/// VIP 지정·변경 시트 (S-045): 표시 이름과 아이콘
struct VIPEditor: View {
    @Environment(AppModel.self) private var model
    @State private var vip: VIP
    private let isNew: Bool

    init(vip: VIP, isNew: Bool) {
        _vip = State(initialValue: vip)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("주소"), value: vip.address)
                TextField(L("표시 이름"), text: $vip.name, prompt: Text(vip.address))
            } footer: {
                Text(L("사이드바 VIP 아래에 이 이름으로 보입니다. 메일의 보낸 사람 이름은 바뀌지 않습니다."))
            }
            Section(L("아이콘")) {
                SymbolPicker(symbol: $vip.symbol)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fitsContent()
        .navigationTitle(isNew ? L("VIP로 지정") : L("VIP 변경"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("취소")) { model.editingVIP = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? L("지정") : L("저장")) { model.saveVIP(vip) }
            }
        }
        .noInitialFocus()
    }
}

/// 스마트 메일상자 만들기·고치기 시트 (S-046)
struct SmartMailboxEditor: View {
    @Environment(AppModel.self) private var model
    @State private var box: SmartMailbox
    private let isNew: Bool

    init(box: SmartMailbox, isNew: Bool) {
        _box = State(initialValue: box)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section {
                TextField(L("이름"), text: $box.name, prompt: Text(L("예: 오늘 받은 첨부")))
                Picker(L("다음 조건을"), selection: $box.matchAll) {
                    Text(L("모두 만족")).tag(true)
                    Text(L("하나라도 만족")).tag(false)
                }
            }
            Section {
                ForEach($box.conditions) { $condition in
                    ConditionRow(condition: $condition, folders: model.folders) {
                        box.conditions.removeAll { $0.id == condition.id }
                    }
                }
                Button(L("조건 추가"), systemImage: "plus") {
                    box.conditions.append(.init(field: .sender))
                }
            } header: {
                Text(L("조건"))
            } footer: {
                Text(L("모든 폴더의 최근 메일 100통에서 찾습니다. 폴더 조건이 없으면 지운 편지함과 정크 메일은 뺍니다."))
            }
            Section(L("아이콘")) {
                SymbolPicker(symbol: $box.symbol)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fitsContent()
        .navigationTitle(isNew ? L("새 스마트 메일상자") : L("스마트 메일상자 변경"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("취소")) { model.editingSmart = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? L("만들기") : L("저장")) { model.saveSmart(box) }
                    .disabled(!box.isValid)
            }
        }
        .noInitialFocus()
    }
}

/// 조건 한 줄: 종류, 값, 빼기
private struct ConditionRow: View {
    @Binding var condition: SmartMailbox.Condition
    let folders: [MailFolder]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Picker(L("조건"), selection: $condition.field) {
                ForEach(SmartMailbox.Field.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            switch condition.field {
            case .sender, .subject:
                TextField(L("글자"), text: $condition.value, prompt: Text(condition.field == .sender ? L("이름 또는 주소") : L("찾을 글자")))
                    .labelsHidden()
            case .receivedWithinDays:
                TextField(L("일수"), text: $condition.value, prompt: Text("7"))
                    .labelsHidden()
                    .frame(width: 64)
                Text(L("일"))
                    .foregroundStyle(.secondary)
                Spacer()
            case .folder:
                Picker(L("폴더"), selection: $condition.value) {
                    Text(L("폴더 고르기")).tag("")
                    ForEach(folders) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden()
            default:
                Spacer()
            }
            Button(L("조건 빼기"), systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(L("이 조건을 뺍니다"))
        }
    }
}
