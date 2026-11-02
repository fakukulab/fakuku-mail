import ExchangeMailKit
import SwiftUI

/// 설정 > 규칙 (S-039): Exchange 받은 편지함 서버 규칙. 앱이 꺼져 있어도 서버가 적용한다.
struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [MessageRule] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        Section {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if rules.isEmpty {
                Text("규칙이 없습니다.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Toggle(isOn: Binding(get: { rule.isEnabled ?? true }, set: { on in toggle(rule, on) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.displayName)
                            Text(rule.summary { id in model.folders.first { $0.id == id }?.displayName })
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("지우기", systemImage: "trash", role: .destructive) { delete(rule) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("이 규칙 지우기")
                }
            }
            Button("규칙 추가…") { adding = true }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("받은 편지함 규칙")
        } footer: {
            Text("Exchange 서버 규칙이라 이 앱이 꺼져 있어도 적용되고, Outlook에도 같은 규칙이 보입니다.")
                .foregroundStyle(.secondary)
        }
        .task { await load() }
        .sheet(isPresented: $adding) {
            RuleEditor(folders: model.folders) { draft in
                adding = false
                Task { await add(draft) }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            rules = try await model.service.rules()
            problem = nil
        } catch {
            problem = "규칙을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func toggle(_ rule: MessageRule, _ on: Bool) {
        Task {
            do {
                try await model.service.setRule(id: rule.id, enabled: on)
                if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i].isEnabled = on }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func delete(_ rule: MessageRule) {
        guard TextPrompt.confirm("\"\(rule.displayName)\" 규칙을 지울까요?", message: "Outlook에서도 사라집니다.", action: "지우기") else { return }
        Task {
            do {
                try await model.service.deleteRule(id: rule.id)
                rules.removeAll { $0.id == rule.id }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func add(_ draft: RuleDraft) async {
        do {
            let next = (rules.compactMap(\.sequence).max() ?? 0) + 1
            rules.append(try await model.service.createRule(draft.rule(sequence: next)))
            problem = nil
        } catch {
            problem = "규칙을 만들지 못했습니다: \(error.localizedDescription)"
        }
    }
}

/// 규칙 추가 시트: 조건 하나, 동작 하나
struct RuleEditor: View {
    let folders: [MailFolder]
    let save: (RuleDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var field = RuleDraft.Field.sender
    @State private var text = ""
    @State private var actionKind = 0
    @State private var folderID: String?

    private var draft: RuleDraft? {
        let action: RuleDraft.Action
        switch actionKind {
        case 0:
            guard let folderID else { return nil }
            action = .move(folderID: folderID)
        case 1: action = .markRead
        case 2: action = .importanceHigh
        default: action = .delete
        }
        let d = RuleDraft(name: name, field: field, text: text, action: action)
        return d.isValid ? d : nil
    }

    var body: some View {
        Form {
            TextField("이름", text: $name, prompt: Text("비우면 조건 글자"))
            Picker("조건", selection: $field) {
                Text("보낸 사람에").tag(RuleDraft.Field.sender)
                Text("제목에").tag(RuleDraft.Field.subject)
            }
            TextField("포함하는 글자", text: $text, prompt: Text("쉼표로 여러 개: 견적, 발주"))
            Picker("동작", selection: $actionKind) {
                Text("폴더로 이동").tag(0)
                Text("읽음으로 표시").tag(1)
                Text("중요도 높음").tag(2)
                Text("지우기").tag(3)
            }
            if actionKind == 0 {
                Picker("폴더", selection: $folderID) {
                    Text("고르세요").tag(String?.none)
                    ForEach(folders) { f in
                        Text(String(repeating: "    ", count: f.depth ?? 0) + f.displayName).tag(String?.some(f.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("취소") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("추가") { if let draft { save(draft) } }
                    .disabled(draft == nil)
            }
        }
    }
}

/// 설정 > 자동 응답 (S-040)
struct AutoReplySettings: View {
    @Environment(AppModel.self) private var model
    @State private var on = false
    @State private var useDates = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(7 * 86_400)
    @State private var audience = "none"
    @State private var internalText = ""
    @State private var externalText = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var status: String?

    var body: some View {
        Section {
            Toggle("자동 응답 보내기", isOn: $on)
            Toggle("기간 정하기", isOn: $useDates)
                .disabled(!on)
            if useDates {
                DatePicker("시작", selection: $start)
                DatePicker("끝", selection: $end, in: start...)
            }
        } header: {
            Text("부재중 자동 응답")
        }
        .disabled(!loaded)
        Section("조직 안 사람에게") {
            TextEditor(text: $internalText)
                .frame(height: 96)
        }
        .disabled(!loaded || !on)
        Section {
            Picker("보낼 대상", selection: $audience) {
                Text("보내지 않음").tag("none")
                Text("연락처에 있는 사람만").tag("contactsOnly")
                Text("모두").tag("all")
            }
            if audience != "none" {
                TextEditor(text: $externalText)
                    .frame(height: 96)
            }
        } header: {
            Text("조직 밖 사람에게")
        }
        .disabled(!loaded || !on)
        Section {
            HStack {
                if let status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("저장") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!loaded || saving || (useDates && end <= start))
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let s = try await model.service.automaticReplies()
            on = s.isOn
            useDates = s.status == "scheduled"
            if let d = s.scheduledStartDateTime?.date { start = d }
            if let d = s.scheduledEndDateTime?.date { end = d }
            audience = s.externalAudience ?? "none"
            internalText = AutomaticReplies.plain(s.internalReplyMessage)
            externalText = AutomaticReplies.plain(s.externalReplyMessage)
            loaded = true
            status = nil
        } catch {
            status = "불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let settings = AutomaticReplies.make(on: on, start: useDates ? start : nil, end: useDates ? end : nil,
                                             audience: audience, internalText: internalText, externalText: externalText)
        do {
            try await model.service.setAutomaticReplies(settings)
            status = on ? "자동 응답을 켰습니다." : "자동 응답을 껐습니다."
        } catch {
            status = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }
}
