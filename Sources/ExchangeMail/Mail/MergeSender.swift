import ExchangeMailKit
import Foundation
import Observation

/// 개별 발송 실행기 (M18). 그룹의 한 사람마다 받는 사람 칸에 그 사람만 넣은 메일을 따로 만들어,
/// 무작위 간격과 시간당 한도를 지키며 하나씩 보낸다. 창을 닫아도 앱이 켜져 있는 동안 계속 보낸다.
@Observable
final class MergeSender {
    enum Status: Equatable { case idle, running, paused, finished, cancelled }

    enum EntryState: Equatable {
        case pending, sending, sent
        case failed(String)
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let name: String
        let email: String
        var state: EntryState = .pending
        var at: Date?
    }

    struct Options: Equatable {
        var pacing = SendPacing.Preset.careful.pacing
        /// List-Unsubscribe 헤더 (받는 쪽 메일 앱의 "구독 취소" 단추)
        var unsubscribeHeader = true
        /// 본문 끝의 구독 취소 안내 문구
        var unsubscribeFooter = false
        var signatureID: UUID?
        var importance = "normal"
    }

    private(set) var status = Status.idle
    private(set) var entries: [Entry] = []
    /// 다음 메일을 보낼 시각 (기다리는 중일 때)
    private(set) var nextSendAt: Date?
    private(set) var title = ""
    private(set) var lastProblem: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sentTimes: [Date] = []
    /// 기다리기 (셀프 테스트는 바로 넘어가게 바꾼다)
    @ObservationIgnored var sleeper: (Double) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }

    var sentCount: Int { entries.filter { $0.state == .sent }.count }
    var failedCount: Int { entries.filter { if case .failed = $0.state { true } else { false } }.count }
    var remainingCount: Int { entries.filter { $0.state == .pending || $0.state == .sending }.count }
    var isActive: Bool { status == .running || status == .paused }

    /// 본문 끝의 구독 취소 줄 (눈에 보이는 링크). 누르면 보낸 사람에게 "구독 취소" 메일이 열린다.
    static func footerHTML(me: String) -> String {
        let subject = L("구독 취소 Unsubscribe").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unsubscribe"
        let link = "mailto:\(me)?subject=\(subject)"
        return """
        <div style="margin-top:24px;font-size:12px;color:#888888">이 메일을 더 받고 싶지 않으시면 \
        <a href="\(link)">구독 취소</a>를 눌러 주세요. \
        If you no longer wish to receive these emails, <a href="\(link)">unsubscribe</a>.</div>
        """
    }

    // MARK: 메일 만들기

    /// 한 사람에게 보낼 제목과 본문
    static func render(_ template: MergeTemplate, for member: MergeMember, signature: Signature?,
                       footer: Bool, me: String = "") -> (subject: String, html: String) {
        let subject = MailMerge.render(template.subject, for: member, html: false)
        var extra = ""
        if signature != nil { extra += SignatureComposer.block(for: signature) }
        if footer && !me.isEmpty { extra += footerHTML(me: me) }
        // 가져온 HTML 템플릿은 </body></html>로 끝나므로, 그 뒤가 아니라 </body> 앞에 넣는다
        // (</html> 뒤의 내용은 Outlook 등이 버린다).
        let html = MailMerge.appendToBody(MailMerge.render(template.html, for: member, html: true), extra)
        return (subject, html)
    }

    /// 한 사람에게 보낼 MIME
    static func mime(_ template: MergeTemplate, for member: MergeMember, options: Options, app: AppModel) throws -> Data {
        let me = app.auth.email ?? ""
        // 구독 취소 체크 하나가 헤더(List-Unsubscribe)와 본문 끝의 구독 취소 링크를 함께 넣는다.
        let rendered = render(template, for: member, signature: app.signatures.signature(id: options.signatureID),
                              footer: options.unsubscribeHeader, me: me)
        let to = AddressParser.format([MailAddress(name: member.name.isEmpty ? nil : member.name, address: member.email)])
        let input = ComposeSender.Input(
            from: MailAddress(name: app.auth.displayName, address: me),
            to: to, cc: "", bcc: "", subject: rendered.subject, bodyHTML: rendered.html,
            files: [], extraAttachments: [], draft: ComposeDraft(),
            fixEnabled: UserDefaults.standard.object(forKey: "fixEnabled") as? Bool ?? true,
            importance: options.importance, replyTo: "",
            listUnsubscribe: options.unsubscribeHeader && !me.isEmpty
                ? "mailto:\(me)?subject=\((L("구독 취소 Unsubscribe")).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unsubscribe")"
                : nil)
        let plan = try ComposeSender.prepare(input, options: ComposeSender.defaultOptions(), forDraft: false)
        guard plan.uploads.isEmpty else { throw MergeProblem.tooLarge }
        return plan.mime
    }

    enum MergeProblem: LocalizedError {
        case tooLarge
        var errorDescription: String? {
            L("본문 그림이 커서 4MB를 넘습니다. 그림을 줄이거나 링크로 바꿔 주세요.")
        }
    }

    // MARK: 실행

    /// 시험 발송: 첫 받는 사람의 내용으로 나에게 한 통
    static func sendTest(_ template: MergeTemplate, sample: MergeMember, options: Options, app: AppModel) async throws {
        guard let me = app.auth.email else { return }
        var mine = sample
        mine.email = me
        var test = template
        test.subject = L("[시험] ") + template.subject
        try await app.service.sendMIME(try mime(test, for: mine, options: options, app: app))
    }

    func start(template: MergeTemplate, group: MergeGroup, options: Options, app: AppModel) {
        guard !isActive else { return }
        let members = group.sendable
        entries = members.map { Entry(id: $0.id, name: $0.name, email: $0.email) }
        title = "\(template.name) → \(group.name)"
        status = .running
        lastProblem = nil
        task = Task { [weak self] in
            await self?.run(template: template, members: members, options: options, app: app)
        }
    }

    func pause() { if status == .running { status = .paused } }
    func resume() { if status == .paused { status = .running } }

    func cancel() {
        guard isActive else { return }
        status = .cancelled
        nextSendAt = nil
        task?.cancel()
    }

    /// 끝난 작업을 지운다 (다음 발송 준비)
    func clear() {
        guard !isActive else { return }
        status = .idle
        entries = []
        title = ""
        lastProblem = nil
    }

    private func run(template: MergeTemplate, members: [MergeMember], options: Options, app: AppModel) async {
        for (index, member) in members.enumerated() {
            // 일시 정지면 다시 누를 때까지 기다린다.
            while status == .paused && !Task.isCancelled { await sleeper(1) }
            guard !Task.isCancelled, status == .running else { return }

            // 시간당 한도
            let wait = options.pacing.hourlyWait(sentAt: sentTimes, now: Date())
            if wait > 0 {
                nextSendAt = Date().addingTimeInterval(wait)
                await sleeper(wait)
                nextSendAt = nil
                guard !Task.isCancelled, status != .cancelled else { return }
            }

            entries[index].state = .sending
            entries[index].state = await sendOne(template, member, options: options, app: app)
            entries[index].at = Date()
            sentTimes.append(Date())

            // 다음 사람까지 무작위 간격
            if index < members.count - 1 {
                let gap = options.pacing.gap(random: Double.random(in: 0...1))
                nextSendAt = Date().addingTimeInterval(gap)
                await sleeper(gap)
                nextSendAt = nil
            }
        }
        if status == .running { status = .finished }
        await app.loadFolders()
    }

    /// 한 사람에게 보낸다. Exchange가 "너무 많이 보냄"(429, 503)이면 쉬었다가 두 번까지 다시 해 본다.
    private func sendOne(_ template: MergeTemplate, _ member: MergeMember, options: Options, app: AppModel) async -> EntryState {
        let data: Data
        do {
            data = try Self.mime(template, for: member, options: options, app: app)
        } catch {
            return .failed(error.localizedDescription)
        }
        var backoff = 120.0
        for attempt in 0..<3 {
            do {
                try await app.service.sendMIME(data)
                app.addressBook.noteSent([MailAddress(name: member.name, address: member.email)], me: app.auth.email)
                return .sent
            } catch let error as GraphError where (error.status == 429 || error.status == 503) && attempt < 2 {
                lastProblem = L("Exchange가 잠시 보내기를 제한했습니다. \(Int(backoff))초 쉬고 다시 보냅니다.")
                nextSendAt = Date().addingTimeInterval(backoff)
                await sleeper(backoff)
                nextSendAt = nil
                backoff *= 2
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .failed(L("Exchange가 계속 제한해 보내지 못했습니다."))
    }
}
