import AppKit
import ExchangeMailKit
import SwiftUI
import UniformTypeIdentifiers

/// 메시지 > 개별 발송… (M18): 템플릿, 받는 사람 그룹, 보내기.
struct MergeWindow: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.send

    enum Tab: Hashable { case templates, groups, send }

    var body: some View {
        TabView(selection: $tab) {
            MergeTemplatesPane()
                .tabItem { Label("템플릿", systemImage: "doc.richtext") }
                .tag(Tab.templates)
            MergeGroupsPane()
                .tabItem { Label("그룹", systemImage: "person.3") }
                .tag(Tab.groups)
            MergeSendPane()
                .tabItem { Label("보내기", systemImage: "paperplane") }
                .tag(Tab.send)
        }
        .padding(Space.lg)
        .navigationTitle("개별 발송")
        .noInitialFocus()
    }
}

// MARK: 템플릿

private struct MergeTemplatesPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var editor = RichTextController()
    @State private var showSource = false
    @State private var source = ""
    @State private var loadedID: UUID?

    private var store: MergeStore { model.merge }

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.templates) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name.isEmpty ? "이름 없는 템플릿" : t.name).lineLimit(1)
                            Text(t.subject.isEmpty ? "제목 없음" : t.subject)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, Space.xs)
                        .tag(t.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if store.templates.isEmpty {
                        ContentUnavailableView("템플릿 없음", systemImage: "doc.richtext",
                                               description: Text("+를 눌러 만드세요."))
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button("템플릿 추가", systemImage: "plus") { selection = store.addTemplate().id }
                    Button("템플릿 삭제", systemImage: "minus") {
                        if let id = selection {
                            store.removeTemplate(id)
                            selection = store.templates.first?.id
                        }
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(Space.sm)
            }
            .frame(width: 220)
            .overlay(RoundedRectangle(cornerRadius: Space.sm).strokeBorder(.separator))
            editorPane
        }
        .onAppear {
            if selection == nil { selection = store.templates.first?.id }
            editor.onUserEdit = { html in
                if let id = loadedID, var t = store.template(id) {
                    t.html = html
                    store.save(t)
                }
            }
            load()
        }
        .onChange(of: selection) { _, _ in
            showSource = false
            load()
        }
        .onChange(of: showSource) { _, on in
            if on { source = store.template(selection)?.html ?? "" } else { load(force: true) }
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let id = selection, let t = store.template(id) {
            VStack(alignment: .leading, spacing: Space.md) {
                Grid(alignment: .leading, horizontalSpacing: Space.sm, verticalSpacing: Space.sm) {
                    GridRow {
                        Text("이름:").gridColumnAlignment(.trailing)
                        TextField("이름", text: binding(t, \.name))
                    }
                    GridRow {
                        Text("제목:")
                        TextField("제목", text: binding(t, \.subject), prompt: Text("예: {{이름}}님께 드리는 안내"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                HStack(spacing: Space.sm) {
                    Menu("자리표시자 넣기") {
                        ForEach(placeholderKeys, id: \.self) { key in
                            Button("{{\(key)}}") { editor.insertHTML("{{\(key)}}") }
                        }
                    }
                    .fixedSize()
                    .disabled(showSource)
                    .help("받는 사람마다 바뀌는 값을 본문에 넣습니다")
                    Button("HTML 파일 가져오기…") { importHTML(into: t) }
                        .help("다른 곳에서 만든 HTML 이메일을 본문으로 가져옵니다")
                    Spacer()
                    Toggle("HTML", isOn: $showSource)
                        .toggleStyle(.button)
                        .help("HTML 소스를 직접 고칩니다")
                }
                .controlSize(.small)
                VStack(spacing: 0) {
                    if showSource {
                        TextEditor(text: $source)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: source) { _, text in
                                if var current = store.template(id) {
                                    current.html = text
                                    store.save(current)
                                }
                            }
                    } else {
                        ScrollView(.horizontal) { FormatToolbar(controller: editor) }
                            .scrollIndicators(.never)
                        Divider()
                        RichTextEditor(controller: editor)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Space.xs).strokeBorder(.separator))
                Text("{{이름}}, {{이메일}}과 그룹 CSV의 열 이름({{회사}} 등)이 받는 사람마다 바뀝니다. 고친 내용은 바로 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView("템플릿을 고르세요", systemImage: "doc.richtext",
                                   description: Text("왼쪽에서 고르거나 +를 눌러 만드세요."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var placeholderKeys: [String] {
        var keys = ["이름", "이메일"]
        for g in store.groups { for k in g.placeholders where !keys.contains(k) { keys.append(k) } }
        return keys
    }

    private func binding(_ t: MergeTemplate, _ key: WritableKeyPath<MergeTemplate, String>) -> Binding<String> {
        Binding(get: { store.template(t.id)?[keyPath: key] ?? "" },
                set: { value in
                    if var current = store.template(t.id) {
                        current[keyPath: key] = value
                        store.save(current)
                    }
                })
    }

    private func load(force: Bool = false) {
        guard let id = selection, let t = store.template(id) else { loadedID = nil; return }
        if loadedID == id && !force { return }
        loadedID = id
        editor.setHTML(t.html)
    }

    private func importHTML(into t: MergeTemplate) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var current = store.template(t.id) ?? t
        current.html = text
        store.save(current)
        showSource = false
        load(force: true)
    }
}

// MARK: 그룹

private struct MergeGroupsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var memberSelection = Set<UUID>()
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var notice: String?

    private var store: MergeStore { model.merge }

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.groups) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name.isEmpty ? "이름 없는 그룹" : g.name).lineLimit(1)
                            Text("\(g.sendable.count)명")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Space.xs)
                        .tag(g.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if store.groups.isEmpty {
                        ContentUnavailableView("그룹 없음", systemImage: "person.3", description: Text("+를 눌러 만드세요."))
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button("그룹 추가", systemImage: "plus") { selection = store.addGroup().id }
                    Button("그룹 삭제", systemImage: "minus") {
                        if let id = selection {
                            store.removeGroup(id)
                            selection = store.groups.first?.id
                        }
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(Space.sm)
            }
            .frame(width: 220)
            .overlay(RoundedRectangle(cornerRadius: Space.sm).strokeBorder(.separator))
            if let id = selection, let g = store.group(id) {
                members(of: g)
            } else {
                ContentUnavailableView("그룹을 고르세요", systemImage: "person.3",
                                       description: Text("왼쪽에서 고르거나 +를 눌러 만드세요."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.groups.first?.id } }
    }

    private func members(of g: MergeGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text("이름:")
                TextField("그룹 이름", text: Binding(get: { store.group(g.id)?.name ?? "" },
                                                 set: { v in if var cur = store.group(g.id) { cur.name = v; store.save(cur) } }))
                    .textFieldStyle(.roundedBorder)
                Button("CSV 가져오기…") { importCSV(into: g) }
                    .help("첫 줄에 이름, 이메일(그리고 회사 같은 다른 열)이 있는 CSV를 가져옵니다")
            }
            Table(g.members, selection: $memberSelection) {
                TableColumn("이름") { m in Text(m.name) }
                TableColumn("이메일") { m in
                    Text(m.email).foregroundStyle(m.isValid ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                }
                TableColumn("다른 값") { m in
                    Text(m.fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            .onDeleteCommand { removeSelected(from: g) }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("빼기") {
                    memberSelection = ids
                    removeSelected(from: g)
                }
            }
            HStack(spacing: Space.sm) {
                TextField("이름", text: $newName).frame(width: 140)
                TextField("이메일", text: $newEmail).frame(width: 220)
                    .onSubmit { add(to: g) }
                Button("추가") { add(to: g) }
                    .disabled(!newEmail.contains("@"))
                Button("선택한 사람 빼기") { removeSelected(from: g) }
                    .disabled(memberSelection.isEmpty)
                Spacer()
            }
            .textFieldStyle(.roundedBorder)
            Text(notice ?? summary(g))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ g: MergeGroup) -> String {
        let bad = g.members.count - g.members.filter(\.isValid).count
        let duplicate = g.members.filter(\.isValid).count - g.sendable.count
        var parts = ["보낼 사람 \(g.sendable.count)명"]
        if bad > 0 { parts.append("틀린 주소 \(bad)개(빨간색)는 보내지 않음") }
        if duplicate > 0 { parts.append("겹치는 주소 \(duplicate)개는 한 번만") }
        return parts.joined(separator: " · ")
    }

    private func add(to g: MergeGroup) {
        let m = MergeMember(name: newName, email: newEmail)
        guard m.isValid, var cur = store.group(g.id) else {
            notice = "주소 형식이 맞지 않습니다: \(newEmail)"
            return
        }
        cur.members.append(m)
        store.save(cur)
        newName = ""
        newEmail = ""
        notice = nil
    }

    private func removeSelected(from g: MergeGroup) {
        guard var cur = store.group(g.id) else { return }
        cur.members.removeAll { memberSelection.contains($0.id) }
        store.save(cur)
        memberSelection = []
    }

    private func importCSV(into g: MergeGroup) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        // 엑셀에서 저장한 CSV는 UTF-8이 아닐 수 있다 (EUC-KR).
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))))
            ?? String(decoding: data, as: UTF8.self)
        let result = MailMerge.members(fromCSV: text)
        guard var cur = store.group(g.id) else { return }
        cur.members += result.members
        store.save(cur)
        notice = result.members.isEmpty
            ? "가져온 사람이 없습니다. 첫 줄에 \"이메일\"(또는 email) 열이 있어야 합니다."
            : "\(result.members.count)명을 가져왔습니다" + (result.skipped > 0 ? ", 주소가 틀린 \(result.skipped)줄은 건너뛰었습니다." : ".")
    }
}

// MARK: 보내기

private struct MergeSendPane: View {
    @Environment(AppModel.self) private var model
    @State private var templateID: UUID?
    @State private var groupID: UUID?
    @State private var preset = SendPacing.Preset.careful
    @State private var options = MergeSender.Options()
    @State private var previewMember: UUID?
    @State private var confirm = false
    @State private var message: String?

    private var sender: MergeSender { model.mergeSender }
    private var template: MergeTemplate? { model.merge.template(templateID) }
    private var group: MergeGroup? { model.merge.group(groupID) }

    var body: some View {
        if sender.status != .idle {
            MergeProgressView()
        } else {
            setup
        }
    }

    /// 왼쪽: 1 무엇을 누구에게 → 2 어떻게 → 요약과 단추. 오른쪽: 받는 사람마다의 미리보기.
    private var setup: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.lg) {
                step(1, "무엇을 누구에게") {
                    row("템플릿") {
                        Picker("템플릿", selection: $templateID) {
                            Text("고르세요").tag(UUID?.none)
                            ForEach(model.merge.templates) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                    row("받는 그룹") {
                        Picker("받는 그룹", selection: $groupID) {
                            Text("고르세요").tag(UUID?.none)
                            ForEach(model.merge.groups) { Text("\($0.name) (\($0.sendable.count)명)").tag(UUID?.some($0.id)) }
                        }
                    }
                }
                step(2, "어떻게") {
                    row("발송 간격") {
                        Picker("발송 간격", selection: $preset) {
                            ForEach(SendPacing.Preset.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .onChange(of: preset) { _, p in options.pacing = p.pacing }
                    }
                    row("서명") {
                        Picker("서명", selection: $options.signatureID) {
                            Text("없음").tag(UUID?.none)
                            ForEach(model.signatures.signatures) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                    row("우선 순위") {
                        Picker("우선 순위", selection: $options.importance) {
                            Text("보통").tag("normal")
                            Text("높음").tag("high")
                            Text("낮음").tag("low")
                        }
                        .pickerStyle(.segmented)
                    }
                    // 줄 레이블을 가리는 row()의 labelsHidden 때문에 체크 옆 글자는 따로 둔다.
                    row("수신 거부") {
                        HStack(spacing: Space.xs) {
                            Toggle("수신 거부 단추 넣기", isOn: $options.unsubscribeHeader)
                            Text("본문 끝에 수신 거부 링크와 수신 거부 헤더 넣기")
                        }
                        .help("본문 맨 끝에 '수신 거부' 링크를 붙이고, List-Unsubscribe 헤더도 넣습니다. "
                              + "Gmail·Outlook이 헤더를 보고 '구독 취소' 단추를 보일지는 그 메일 앱이 정합니다.")
                    }
                }
                DisclosureGroup("스팸으로 보이지 않게 이렇게 보냅니다") {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("• 한 사람에게 한 통씩, 받는 사람 칸에 그 사람만 (숨은 참조 대량 발송 아님)")
                        Text("• 간격 안에서 무작위로 쉬고, 시간당 한도를 넘지 않음")
                        Text("• 자리표시자로 사람마다 내용이 다름")
                        Text("• Exchange가 제한하면(429) 쉬었다가 다시 보냄")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
                }
                .font(.callout)
                Spacer(minLength: 0)
                Divider()
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    SettingsNote(message)
                }
                HStack(spacing: Space.sm) {
                    Button("나에게 시험 발송") { sendTest() }
                        .disabled(!ready)
                    Spacer()
                    Button("발송 시작…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready)
                }
            }
            .frame(width: 380)
            preview
        }
        .onAppear {
            templateID = templateID ?? model.merge.templates.first?.id
            groupID = groupID ?? model.merge.groups.first?.id
        }
        .alert("개별 발송을 시작할까요?", isPresented: $confirm) {
            Button("시작") { start() }
            Button("취소", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
    }

    /// 단계 한 덩어리: "1  무엇을 누구에게" 제목과 그 아래 줄들
    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 20, height: 20)
                    .background(Palette.accent, in: Circle())
                Text(title).font(.headline)
            }
            content()
        }
    }

    /// 단계 안의 한 줄: 같은 너비 레이블 + 컨트롤
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 보내기 전 한 줄 요약
    private var summaryText: String {
        guard let template, let group else { return "템플릿과 받는 그룹을 고르세요." }
        let count = group.sendable.count
        guard count > 0 else { return "\(group.name) 그룹에 보낼 사람이 없습니다. 그룹 탭에서 사람을 넣으세요." }
        let minutes = Int(options.pacing.estimatedSeconds(count: count) / 60)
        return "'\(template.name)'을(를) \(group.name)의 \(count)명에게 한 통씩 보냅니다. 약 \(minutes)분 걸립니다."
    }

    private var ready: Bool { template != nil && !(group?.sendable.isEmpty ?? true) && model.isSignedIn }

    private var confirmText: String {
        let count = group?.sendable.count ?? 0
        let minutes = Int(options.pacing.estimatedSeconds(count: count) / 60)
        return "\(count)명에게 한 통씩 보냅니다. 다 보내기까지 약 \(minutes)분 걸립니다. 앱을 켜 두세요. 중간에 멈추거나 그만둘 수 있습니다."
    }

    /// 미리보기: 고른 받는 사람으로 채운 제목과 본문
    @ViewBuilder
    private var preview: some View {
        if let template, let group, !group.sendable.isEmpty {
            let member = group.sendable.first { $0.id == previewMember } ?? group.sendable[0]
            let rendered = MergeSender.render(template, for: member,
                                              signature: model.signatures.signature(id: options.signatureID),
                                              footer: options.unsubscribeHeader, me: model.auth.email ?? "")
            let missing = MailMerge.placeholders(in: template.subject + template.html)
                .filter { key in group.sendable.contains { MailMerge.render("{{\(key)}}", for: $0, html: false).isEmpty } }
            VStack(alignment: .leading, spacing: Space.sm) {
                Picker("미리보기:", selection: Binding(get: { member.id }, set: { previewMember = $0 })) {
                    ForEach(group.sendable) { Text("\($0.name) <\($0.email)>").tag($0.id) }
                }
                Text("받는 사람: \(member.name) <\(member.email)>")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(rendered.subject.isEmpty ? "(제목 없음)" : rendered.subject)
                    .font(.headline)
                HTMLView(html: MailContent.page(body: .init(contentType: "html", content: rendered.html), allowRemote: true))
                    .overlay(RoundedRectangle(cornerRadius: Space.xs).strokeBorder(.separator))
                if !missing.isEmpty {
                    Label("값이 빈 받는 사람이 있는 자리표시자: \(missing.map { "{{\($0)}}" }.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            ContentUnavailableView("미리보기", systemImage: "eye",
                                   description: Text("템플릿과 사람이 있는 그룹을 고르면 받는 사람마다 어떻게 보이는지 볼 수 있습니다."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sendTest() {
        guard let template, let sample = group?.sendable.first else { return }
        message = "시험 메일을 보내는 중…"
        Task {
            do {
                try await MergeSender.sendTest(template, sample: sample, options: options, app: model)
                message = "\(model.auth.email ?? "나")에게 시험 메일을 보냈습니다. 받은 편지함에서 확인하세요."
            } catch {
                message = "시험 발송 실패: \(error.localizedDescription)"
            }
        }
    }

    private func start() {
        guard let template, let group else { return }
        sender.start(template: template, group: group, options: options, app: model)
    }
}

/// 발송 진행: 보낸 수, 다음 발송까지 남은 시간, 일시 정지·계속·중지, 사람별 결과
private struct MergeProgressView: View {
    @Environment(AppModel.self) private var model
    private var sender: MergeSender { model.mergeSender }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(sender.title).font(.headline)
            ProgressView(value: Double(sender.sentCount + sender.failedCount), total: Double(max(sender.entries.count, 1)))
            HStack(spacing: Space.lg) {
                Text("보냄 \(sender.sentCount) · 실패 \(sender.failedCount) · 남음 \(sender.remainingCount)")
                    .monospacedDigit()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let next = sender.nextSendAt, sender.status == .running {
                        Text("다음 발송까지 \(max(0, Int(next.timeIntervalSince(context.date))))초")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                switch sender.status {
                case .running:
                    Button("일시 정지") { sender.pause() }
                    Button("중지", role: .destructive) { sender.cancel() }
                case .paused:
                    Button("계속") { sender.resume() }
                    Button("중지", role: .destructive) { sender.cancel() }
                default:
                    Text(sender.status == .finished ? "다 보냈습니다." : "중지했습니다.")
                        .foregroundStyle(.secondary)
                    Button("닫기") { sender.clear() }
                }
            }
            if let problem = sender.lastProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Table(sender.entries) {
                TableColumn("받는 사람") { e in Text(e.name.isEmpty ? e.email : "\(e.name) <\(e.email)>") }
                TableColumn("상태") { e in
                    switch e.state {
                    case .pending: Text("기다리는 중").foregroundStyle(.secondary)
                    case .sending: Text("보내는 중…")
                    case .sent: Label("보냄", systemImage: "checkmark.circle").foregroundStyle(.green)
                    case .failed(let why): Label(why, systemImage: "xmark.circle").foregroundStyle(.red).help(why)
                    }
                }
                TableColumn("시각") { e in
                    Text(e.at.map { $0.formatted(date: .omitted, time: .standard) } ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("앱을 켜 두는 동안 보냅니다. 이 창은 닫아도 됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
