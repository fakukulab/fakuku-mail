import ExchangeMailKit
import SwiftUI

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
            Toggle(L("자동 응답 보내기"), isOn: $on)
            Toggle(L("기간 정하기"), isOn: $useDates)
                .disabled(!on)
            if useDates {
                DatePicker(L("시작"), selection: $start)
                DatePicker(L("끝"), selection: $end, in: start...)
            }
        } header: {
            Text(L("부재중 자동 응답"))
        }
        .disabled(!loaded)
        Section(L("조직 안 사람에게")) {
            TextEditor(text: $internalText)
                .frame(height: 96)
        }
        .disabled(!loaded || !on)
        Section {
            Picker(L("보낼 대상"), selection: $audience) {
                Text(L("보내지 않음")).tag("none")
                Text(L("연락처에 있는 사람만")).tag("contactsOnly")
                Text(L("모두")).tag("all")
            }
            if audience != "none" {
                TextEditor(text: $externalText)
                    .frame(height: 96)
            }
        } header: {
            Text(L("조직 밖 사람에게"))
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
                Button(L("저장")) { Task { await save() } }
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
            status = L("불러오지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let settings = AutomaticReplies.make(on: on, start: useDates ? start : nil, end: useDates ? end : nil,
                                             audience: audience, internalText: internalText, externalText: externalText)
        do {
            try await model.service.setAutomaticReplies(settings)
            status = on ? L("자동 응답을 켰습니다.") : L("자동 응답을 껐습니다.")
        } catch {
            status = L("저장하지 못했습니다: \(error.localizedDescription)")
        }
    }
}
