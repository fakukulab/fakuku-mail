import ExchangeMailKit
import SwiftUI

/// 설정 > 규칙 (S-039, S-075): Outlook과 같은 받은 편지함 규칙. 위에 있는 규칙부터 차례로 적용한다.
/// Exchange 서버 규칙이라 앱이 꺼져 있어도 새 메일에 적용되고, Outlook에도 같은 규칙이 보인다.
struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var accountID: String?
    @State private var rules: [MessageRule] = []
    @State private var loading = true
    @State private var busy = false
    @State private var problem: String?
    @State private var editing: Editing?
    @State private var running: MessageRule?

    /// 편집 창에 넘기는 값: 새 규칙이면 `old`가 nil
    struct Editing: Identifiable {
        let id = UUID()
        var form: RuleForm
        var old: MessageRule?
    }

    private var account: MailAccount? { model.ruleAccount(accountID) }

    var body: some View {
        if model.exchangeAccounts.isEmpty {
            Section {
                ContentUnavailableView(L("규칙을 쓸 Exchange 계정이 없습니다"), systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(L("받은 편지함 규칙은 Microsoft Exchange 서버에 저장됩니다. iCloud·Gmail 계정에는 쓸 수 없습니다.")))
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.exchangeAccounts.count > 1 {
            Section {
                Picker(L("계정"), selection: $accountID) {
                    ForEach(model.exchangeAccounts) { a in
                        Text(a.auth.email ?? a.id).tag(String?.some(a.id))
                    }
                }
            }
        }
        Section {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if rules.isEmpty {
                Text(L("규칙이 없습니다."))
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in row(rule) }
            HStack(spacing: Space.sm) {
                Button(L("규칙 추가…")) { editing = Editing(form: RuleForm(), old: nil) }
                    .disabled(loading || account == nil)
                if busy { ProgressView().controlSize(.small) }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L("받은 편지함 규칙"))
        } footer: {
            Text(L("위에 있는 규칙부터 차례로 적용합니다. Exchange 서버 규칙이라 이 앱이 꺼져 있어도 적용되고, Outlook에도 같은 규칙이 보입니다."))
                .foregroundStyle(.secondary)
        }
        .task(id: account?.id) { await load() }
        .onAppear {
            if accountID == nil { accountID = model.ruleAccount(nil)?.id }
            takeSeed()
        }
        .onChange(of: model.ruleSeed) { takeSeed() }
        .sheet(item: $editing) { e in
            RuleEditor(form: e.form, isNew: e.old == nil, folders: account.map(model.ruleFolders) ?? []) { form in
                editing = nil
                Task { await save(form, replacing: e.old) }
            }
        }
        .sheet(item: $running) { rule in
            if let account {
                RuleRunSheet(rule: rule, account: account, folders: model.ruleFolders(of: account))
            }
        }
    }

    // MARK: 줄

    private func isLocked(_ rule: MessageRule) -> Bool { BlockedSenders.isBlockRule(rule) || rule.isReadOnly == true }

    private func folderName(_ id: String) -> String? {
        guard let account else { return nil }
        return model.ruleFolders(of: account).first { $0.id == id || $0.kind == id }?.displayName
    }

    private func row(_ rule: MessageRule) -> some View {
        let index = rules.firstIndex(of: rule) ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Toggle(isOn: Binding(get: { rule.isEnabled ?? true }, set: { on in toggle(rule, on) })) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Text(rule.displayName)
                        if rule.hasError == true {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(L("Exchange가 이 규칙에 문제가 있다고 알립니다. 옮길 폴더가 지워졌는지 확인하세요."))
                        }
                    }
                    Text(rule.summary(folderName: folderName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if BlockedSenders.isBlockRule(rule) {
                        Text(L("설정 > 정크 메일의 차단 목록이 관리합니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if rule.isReadOnly == true {
                        Text(L("Outlook 데스크톱에서만 고칠 수 있는 규칙입니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button(L("편집…"), systemImage: "pencil") { editing = Editing(form: RuleForm(rule: rule), old: rule) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isLocked(rule) || busy)
                .help(L("이 규칙 편집"))
            Menu {
                Button(L("편집…")) { editing = Editing(form: RuleForm(rule: rule), old: rule) }
                    .disabled(isLocked(rule))
                Button(L("지금 실행…")) { running = rule }
                Divider()
                Button(L("위로 이동")) { move(rule, by: -1) }
                    .disabled(index == 0)
                Button(L("아래로 이동")) { move(rule, by: 1) }
                    .disabled(index == rules.count - 1)
                Divider()
                Button(L("지우기…"), role: .destructive) { delete(rule) }
                    .disabled(BlockedSenders.isBlockRule(rule))
            } label: {
                Label(L("더 보기"), systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            .help(L("지금 실행, 차례 바꾸기, 지우기"))
        }
        .padding(.vertical, Space.xs)
    }

    // MARK: 동작

    private func takeSeed() {
        guard let seed = model.ruleSeed else { return }
        model.ruleSeed = nil
        if let id = seed.accountID, model.exchangeAccounts.contains(where: { $0.id == id }) { accountID = id }
        editing = Editing(form: seed.form, old: nil)
    }

    private func load() async {
        guard let account else { return }
        loading = true
        defer { loading = false }
        do {
            rules = try await model.rules(of: account)
            problem = nil
        } catch {
            problem = L("규칙을 불러오지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func toggle(_ rule: MessageRule, _ on: Bool) {
        guard let account else { return }
        Task {
            do {
                try await account.service.setRule(id: rule.id, enabled: on)
                if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i].isEnabled = on }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func move(_ rule: MessageRule, by offset: Int) {
        guard let account else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                rules = try await model.moveRule(rule, by: offset, in: rules, account: account)
                problem = nil
            } catch {
                problem = L("차례를 바꾸지 못했습니다: \(error.localizedDescription)")
                await load()
            }
        }
    }

    private func delete(_ rule: MessageRule) {
        guard let account,
              TextPrompt.confirm(L("\"\(rule.displayName)\" 규칙을 지울까요?"), message: L("Outlook에서도 사라집니다."), action: L("지우기"))
        else { return }
        Task {
            do {
                try await account.service.deleteRule(id: rule.id)
                rules.removeAll { $0.id == rule.id }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func save(_ form: RuleForm, replacing old: MessageRule?) async {
        guard let account else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await model.saveRule(form, replacing: old, in: account, existing: rules)
            problem = nil
        } catch {
            problem = old == nil
                ? L("규칙을 만들지 못했습니다: \(error.localizedDescription)")
                : L("규칙을 고치지 못했습니다: \(error.localizedDescription)")
        }
        await load()
    }
}

// MARK: 편집 창

/// 규칙 추가·편집 시트 (Outlook 규칙 창과 같은 틀): 이름, 조건, 동작, 예외.
struct RuleEditor: View {
    @State var form: RuleForm
    let isNew: Bool
    let folders: [MailFolder]
    let save: (RuleForm) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField(L("이름"), text: $form.name, prompt: Text(L("비우면 첫 조건")))
            }
            Section {
                ForEach($form.conditions) { $c in
                    RuleConditionRow(condition: $c) { form.conditions.removeAll { $0.id == c.id } }
                }
                addConditionMenu(exceptions: false)
            } header: {
                Text(L("조건"))
            } footer: {
                Text(form.conditions.isEmpty
                     ? L("조건이 없으면 모든 새 메일에 적용됩니다.")
                     : L("모든 조건이 맞을 때 적용합니다. 한 칸에 쉼표로 여러 개를 넣으면 그중 하나만 맞아도 됩니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach($form.actions) { $a in
                    RuleActionRow(action: $a, folders: folders) { form.actions.removeAll { $0.id == a.id } }
                }
                addActionMenu
                Toggle(L("다음 규칙은 처리하지 않음"), isOn: $form.stopProcessing)
            } header: {
                Text(L("동작"))
            }
            Section {
                ForEach($form.exceptions) { $c in
                    RuleConditionRow(condition: $c) { form.exceptions.removeAll { $0.id == c.id } }
                }
                addConditionMenu(exceptions: true)
            } header: {
                Text(L("예외"))
            } footer: {
                Text(L("예외 중 하나라도 맞으면 이 규칙을 건너뜁니다."))
                    .foregroundStyle(.secondary)
            }
            if let problem = form.problem {
                Section {
                    Label(problem, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fitsContent(max: 520)
        .frame(width: 600)
        .noInitialFocus()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("취소")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? L("추가") : L("저장")) { save(form) }
                    .disabled(!form.isValid)
            }
        }
    }

    private func addConditionMenu(exceptions isException: Bool) -> some View {
        let unused = form.unusedConditions(exceptions: isException)
        return Menu(isException ? L("예외 추가") : L("조건 추가")) {
            ForEach(RuleConditionKind.Group.allCases, id: \.self) { group in
                Section(RuleConditionKind.groupTitle(group)) {
                    ForEach(RuleConditionKind.kinds(in: group).filter(unused.contains)) { kind in
                        Button(kind.title) {
                            if isException { form.exceptions.append(.init(kind: kind)) } else { form.conditions.append(.init(kind: kind)) }
                        }
                    }
                }
            }
        }
        .fixedSize()
        .disabled(unused.isEmpty)
    }

    private var addActionMenu: some View {
        let unused = form.unusedActions
        return Menu(L("동작 추가")) {
            ForEach(RuleActionKind.allCases.filter(unused.contains)) { kind in
                Button(kind.title) { form.actions.append(.init(kind: kind)) }
                if kind == .permanentDelete || kind == .assignCategories { Divider() }
            }
        }
        .fixedSize()
        .disabled(unused.isEmpty)
    }
}

/// 조건·예외 한 줄: 종류 이름, 값, 빼기 단추
struct RuleConditionRow: View {
    @Binding var condition: RuleCondition
    let remove: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.sm) {
                input
                RuleRemoveButton(action: remove)
            }
        } label: {
            Text(condition.kind.title)
        }
    }

    @ViewBuilder
    private var input: some View {
        switch condition.kind.input {
        case .none:
            EmptyView()
        case .words:
            TextField(L("글자"), text: $condition.text, prompt: Text(L("쉼표로 여러 개: 견적, 발주")))
                .labelsHidden()
        case .addresses:
            TextField(L("주소"), text: $condition.text, prompt: Text(L("주소, 쉼표로 여러 개")))
                .labelsHidden()
        case .importance:
            RuleValuePicker(values: RuleValue.importance, selection: $condition.choice)
        case .sensitivity:
            RuleValuePicker(values: RuleValue.sensitivity, selection: $condition.choice)
        case .flag:
            RuleValuePicker(values: RuleValue.flag, selection: $condition.choice)
        case .size:
            TextField(L("최소"), value: $condition.minKB, format: .number, prompt: Text("0"))
                .labelsHidden()
                .frame(width: 80)
            Text(verbatim: "–")
            TextField(L("최대"), value: $condition.maxKB, format: .number, prompt: Text(L("끝 없음")))
                .labelsHidden()
                .frame(width: 80)
            Text(verbatim: "KB")
                .foregroundStyle(.secondary)
        }
    }
}

/// 동작 한 줄
struct RuleActionRow: View {
    @Binding var action: RuleAction
    let folders: [MailFolder]
    let remove: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.sm) {
                input
                RuleRemoveButton(action: remove)
            }
        } label: {
            Text(action.kind.title)
        }
    }

    @ViewBuilder
    private var input: some View {
        switch action.kind.input {
        case .none:
            EmptyView()
        case .folder:
            Picker(L("폴더"), selection: $action.folderID) {
                Text(L("고르세요")).tag(String?.none)
                ForEach(folders) { f in
                    Text(String(repeating: "    ", count: f.depth ?? 0) + f.displayName).tag(String?.some(f.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        case .importance:
            RuleValuePicker(values: RuleValue.importance, selection: $action.choice)
        case .words:
            TextField(L("범주"), text: $action.text, prompt: Text(L("범주 이름, 쉼표로 여러 개")))
                .labelsHidden()
        case .addresses:
            TextField(L("주소"), text: $action.text, prompt: Text(L("주소, 쉼표로 여러 개")))
                .labelsHidden()
        }
    }
}

private struct RuleValuePicker: View {
    let values: [String]
    @Binding var selection: String

    var body: some View {
        Picker(L("값"), selection: $selection) {
            ForEach(values, id: \.self) { Text(RuleValue.title($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct RuleRemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(L("빼기"), systemImage: "minus.circle", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(L("이 줄 빼기"))
    }
}

// MARK: 지금 실행

/// 지금 실행 시트: 폴더를 고르면 그 폴더에 이미 있는 메일에 규칙을 적용한다 (Outlook의 "지금 규칙 실행").
struct RuleRunSheet: View {
    let rule: MessageRule
    let account: MailAccount
    let folders: [MailFolder]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folderID: String?
    @State private var running = false
    @State private var status: String?
    @State private var report: RuleRunReport?
    @State private var problem: String?

    private var cannotRun: String? {
        RuleMatcher.unsupported(rule).isEmpty ? nil : RuleRunError.unsupported(RuleMatcher.unsupported(rule)).errorDescription
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("규칙"), value: rule.displayName)
                Picker(L("폴더"), selection: $folderID) {
                    ForEach(folders) { f in
                        Text(String(repeating: "    ", count: f.depth ?? 0) + f.displayName).tag(String?.some(f.id))
                    }
                }
                .disabled(running)
            } footer: {
                Text(L("이 폴더에 이미 있는 메일에 규칙을 지금 적용합니다. 전달·리디렉션 동작은 지금 실행에서 하지 않습니다."))
                    .foregroundStyle(.secondary)
            }
            if let message = cannotRun ?? problem {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else if running || report != nil {
                Section {
                    if running {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Text(status ?? L("준비하는 중…"))
                        }
                    } else if let report {
                        Text(Self.describe(report))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fitsContent(max: 400)
        .frame(width: 480)
        .noInitialFocus()
        .onAppear { folderID = folders.first { $0.kind == "inbox" }?.id ?? folders.first?.id }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(report == nil ? L("취소") : L("닫기")) { dismiss() }
                    .disabled(running)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("실행")) { Task { await run() } }
                    .disabled(running || folderID == nil || cannotRun != nil)
            }
        }
    }

    static func describe(_ r: RuleRunReport) -> String {
        var lines = [L("메일 \(r.scanned)통을 살펴보고 \(r.applied)통에 규칙을 적용했습니다.")]
        if r.failed > 0 { lines.append(L("\(r.failed)통은 적용하지 못했습니다.")) }
        if r.stoppedAtLimit { lines.append(L("최근 메일 \(AppModel.ruleRunLimit)통까지만 살펴봤습니다.")) }
        if r.skippedSending { lines.append(L("전달·리디렉션은 하지 않았습니다. 새로 오는 메일에는 서버가 합니다.")) }
        return lines.joined(separator: "\n")
    }

    private func run() async {
        guard let folderID else { return }
        running = true
        defer { running = false }
        report = nil
        problem = nil
        do {
            report = try await model.runRuleNow(rule, account: account, folderID: folderID) { status = $0 }
        } catch {
            problem = L("실행하지 못했습니다: \(error.localizedDescription)")
        }
    }
}
