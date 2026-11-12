import AppKit
import ExchangeMailKit
import QuickLook
import SwiftUI

struct MessageDetailView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @Environment(\.undoManager) var undoManager
    @AppStorage("list.threaded") private var threaded = true
    // 설정 > 서체 및 색상
    @AppStorage(Prefs.bodyFontFamily) private var bodyFamily = ""
    @AppStorage(Prefs.bodyFontSize) private var bodySize = 14
    @AppStorage(Prefs.plainMonospace) private var plainMonospace = false
    @AppStorage(Prefs.quoteColors) private var quoteColors = true
    @AppStorage(Prefs.quoteColor1) private var quote1 = Prefs.defaultQuoteColors[0]
    @AppStorage(Prefs.quoteColor2) private var quote2 = Prefs.defaultQuoteColors[1]
    @AppStorage(Prefs.quoteColor3) private var quote3 = Prefs.defaultQuoteColors[2]

    private var readingStyle: ReadingStyle {
        ReadingStyle(family: bodyFamily, size: bodySize, plainMonospace: plainMonospace, quoteColors: quoteColors,
                     quote: [quote1, quote2, quote3])
    }

    var body: some View {
        Group {
            if model.multipleSelectionCount > 0 {
                ContentUnavailableView(L("메시지 \(model.multipleSelectionCount)개 선택됨"), systemImage: "tray.full",
                                       description: Text(L("보관, 지우기, 이동, 읽음, 깃발을 한 번에 할 수 있습니다.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let m = model.detail, model.displayedMessageID != nil {
                // 새 메일을 받는 동안에는 지금 보이는 메일을 그대로 둔다 (진행 표시로 비우지 않아 깜빡이지 않는다).
                VStack(alignment: .leading, spacing: 0) {
                    if threaded && model.thread.count > 1 {
                        ThreadStrip()
                        // 잡는 자리가 아래 머리글에 가려지지 않게 앞에 둔다.
                        ThreadResizeHandle()
                            .zIndex(1)
                    }
                    MessageHeader(message: m, attachments: model.listedAttachments) { a in Task { await model.preview(a) } }
                    if model.isDraftSelected {
                        draftBar
                    }
                    UnsubscribeBar(message: m)
                    if m.isMeetingRequest, let event = m.event {
                        MeetingBar(event: event)
                    }
                    let remote = model.detailRemote
                    let page = model.protectedPage(id: m.id, body: model.detailBody, remote: remote, css: readingStyle.css)
                    if model.detailHasRemoteContent {
                        RemoteContentBar(remote: remote, blockedTrackers: page.blockedTrackers) {
                            model.allowRemoteContentForSelection()
                        }
                    }
                    Divider()
                    HTMLView(html: page.html,
                             scroller: model.pageScroller, onPrint: { model.printDisplayed() }) { url in
                        openWindow(id: "compose", value: ComposeDraft.mailto(url))
                    }
                }
            } else if model.selectedMessageID != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.missingMessageNotice {
                ContentUnavailableView(L("메일을 찾을 수 없습니다"), systemImage: "envelope.badge.shield.half.filled",
                                       description: Text(L("다른 기기나 규칙이 이 메일을 옮겼거나 지웠습니다. 목록을 새로 고쳤습니다.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L("메시지를 선택하세요"), systemImage: "envelope")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 새 메일을 받는 동안: 이전 메일을 두고 맨 위에 얇은 진행 막대와 "불러오는 중…"
        .overlay(alignment: .top) {
            if model.isLoadingDetail && model.detail != nil {
                LoadingStrip()
            }
        }
        .toolbar(id: "mail") { mailToolbar }
        // 첨부 미리보기 (S-032)
        .quickLookPreview(Binding(get: { model.previewURL }, set: { model.previewURL = $0 }))
    }

    /// 임시 보관함의 초안: 이어서 쓰기 (S-022)
    private var draftBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "pencil.and.list.clipboard")
                .foregroundStyle(.secondary)
            Text(L("저장된 초안입니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("이어서 쓰기")) {
                if let d = model.resumeDraft() { openWindow(id: "compose", value: d) }
            }
            .controlSize(.small)
            .help(L("작성 창에서 이어서 씁니다 (⌘O)"))
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}

/// 새 메일 본문을 받는 동안 본문 맨 위에 보이는 얇은 진행 막대와 작은 꼬리표.
/// 이전 메일은 그대로 두므로 깜빡이지 않고, 무엇인가 오고 있다는 것만 알린다.
struct LoadingStrip: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Palette.accent)
            Label(L("불러오는 중…"), systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .background(.regularMaterial, in: Capsule())
                .padding(.trailing, Space.sm)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("새 메일을 불러오는 중"))
    }
}

/// 원격 콘텐츠 안내 (본문 열과 메시지 창, S-016, S-047).
/// 막았으면 불러오기를, 메일 활동 보호로 추적기를 뺐으면 그 수를 보인다. 그대로 불러왔으면 아무것도 보이지 않는다.
struct RemoteContentBar: View {
    let remote: RemoteContent
    let blockedTrackers: Int
    let allow: () -> Void

    var body: some View {
        switch remote {
        case .blocked:
            bar(symbol: "photo.badge.exclamationmark",
                text: L("원격 이미지를 차단했습니다. 보낸 사람이 메일을 열었는지 알 수 없게 합니다.")) {
                Button(L("불러오기"), action: allow)
                    .controlSize(.small)
                    .help(L("이 메일의 원격 이미지를 원래 서버에서 불러옵니다 (⇧⌘I)"))
            }
        case .proxied where blockedTrackers > 0:
            bar(symbol: "hand.raised",
                text: L("메일 활동 보호: 추적기 \(blockedTrackers)개를 막았습니다. 그림은 앱이 대신 받았습니다.")) {
                Button(L("원래대로 불러오기"), action: allow)
                    .controlSize(.small)
                    .help(L("추적기를 포함해 원래 서버에서 그대로 불러옵니다. 보낸 사람이 열람을 알 수 있습니다 (⇧⌘I)"))
            }
        default:
            EmptyView()
        }
    }

    private func bar<Action: View>(symbol: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            action()
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}

struct MessageHeader: View {
    let message: MailMessage
    /// 목록에 보일 첨부 (인라인 그림 빼고)
    let attachments: [FileAttachment]
    let preview: (FileAttachment) -> Void
    @Environment(AppModel.self) private var model

    /// 맥 Mail처럼: 왼쪽에 보낸 사람 머리글자 원, 오른쪽에 보낸 사람(굵게)·날짜, 제목, 받는 사람·참조 주소 단추.
    /// 주소 단추를 누르면 주소 메뉴(복사, VIP, 차단, 새 메일, 이전 수신자에서 제거, 검색)가 열린다.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                SenderAvatar(name: message.from?.emailAddress.display ?? "?")
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        if let vip = model.mailboxes.vip(for: message) {
                            VIPBadge(vip: vip)
                        }
                        if let from = message.from {
                            AddressToken(recipient: from, prominent: true)
                        } else {
                            Text(L("(보낸 사람 없음)")).font(.headline)
                        }
                        Spacer(minLength: Space.sm)
                        Text(message.receivedDateTime.map { MailDate.long($0) } ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.title)
                        .textSelection(.enabled)
                    recipientLine
                }
            }
            if !attachments.isEmpty {
                // Outlook처럼 파일 종류 아이콘·이름·크기 카드. 누르면 훑어보기, ⌄ 메뉴,
                // 끌어서 Finder에 저장하거나 작성 창(새 메시지·답장)에 놓아 첨부 (S-032, S-035)
                AttachmentStrip {
                    ForEach(attachments) { a in
                        AttachmentCard(name: FilenameEncoder.normalize(a.name), size: a.size,
                                       preview: { preview(a) },
                                       open: { Task { await model.openAttachment(a, messageID: message.id) } },
                                       save: { Task { await model.save(attachment: a, messageID: message.id) } })
                            .onDrag { model.dragProvider(for: a, messageID: message.id) }
                            // 끌기 전에 내용을 받아 두고, 끌 수 있는 첨부로 기억한다 (놓는 쪽이 빈 끌기를 받아도 이것을 넣는다)
                            .onHover { inside in
                                guard inside else { return }
                                model.warmAttachment(a, messageID: message.id)
                                model.dragCandidate = (a, message.id, Date())
                            }
                    }
                }
                if attachments.count > 1 {
                    Button(L("모두 다운로드…")) { Task { await model.saveAll(attachments, messageID: message.id) } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.lg)
    }

    /// "받는 사람: 김전, 참조: Lorielaine Mendoza, 이정식" — 맥 Mail처럼 한 줄에 이어 붙인다 (많으면 줄을 넘긴다).
    /// 레이블은 진하게, 이름은 흐리게. 이름을 누르면 주소 메뉴.
    @ViewBuilder
    private var recipientLine: some View {
        let to = message.toRecipients ?? []
        let cc = message.ccRecipients ?? []
        if !to.isEmpty || !cc.isEmpty {
            FlowLayout(spacing: Space.xs) {
                if !to.isEmpty {
                    Text(L("받는 사람:"))
                    ForEach(Array(to.enumerated()), id: \.offset) { index, r in
                        AddressToken(recipient: r, trailingComma: index < to.count - 1 || !cc.isEmpty)
                    }
                }
                if !cc.isEmpty {
                    Text(L("참조:"))
                    ForEach(Array(cc.enumerated()), id: \.offset) { index, r in
                        AddressToken(recipient: r, trailingComma: index < cc.count - 1)
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// 보낸 사람 머리글자 원 (연락처 사진 대신)
struct SenderAvatar: View {
    let name: String

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }).filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "?" }
        // 한글 이름은 첫 글자, 영문은 두 단어 첫 글자
        if first.unicodeScalars.first.map({ (0xAC00...0xD7A3).contains($0.value) }) == true { return String(first) }
        let second = words.dropFirst().first?.first.map(String.init) ?? ""
        return (String(first) + second).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.headline)
            .foregroundStyle(Palette.accentText)
            .frame(width: 40, height: 40)
            .background(Palette.accent.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

/// 머리글의 주소 하나 (맥 Mail처럼): 보낸 사람은 굵은 이름, 받는 사람·참조는 흐린 이름.
/// 마우스를 올리면 강조색 바탕과 ⌄가 보이고(올리지 않으면 ⌄는 없다), 누르면 주소 메뉴를 연다.
struct AddressToken: View {
    let recipient: Recipient
    var prominent = false
    var trailingComma = false
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    private var address: String { recipient.emailAddress.address ?? "" }
    private var name: String { recipient.emailAddress.display }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                menuItems
            } label: {
                HStack(spacing: 2) {
                    Text(name)
                        .font(prominent ? .headline : .callout)
                    if hovering {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(hovering ? AnyShapeStyle(Palette.onAccent)
                                 : prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 1)
                .background {
                    if hovering {
                        RoundedRectangle(cornerRadius: Space.xs, style: .continuous).fill(Palette.accent)
                    }
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { hovering = $0 && !address.isEmpty }
            .help(address)
            .disabled(address.isEmpty)
            if trailingComma {
                Text(",")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 맥 Mail의 주소 메뉴와 같은 차례
    @ViewBuilder
    private var menuItems: some View {
        // 맨 위: 체크 표시와 주소 (고를 수 없다)
        Toggle(address, isOn: .constant(true))
            .disabled(true)
        Divider()
        Button(L("주소 복사")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recipient.emailAddress.mailAddress?.editable ?? address, forType: .string)
        }
        if model.mailboxes.vip(address: address) == nil {
            Button(L("VIP에 추가")) { model.editVIP(address: address, name: recipient.emailAddress.name) }
        } else {
            Button(L("VIP에서 제거")) { model.removeVIP(address: address) }
        }
        if model.blockList.onlyApple(address) {
            // Apple 연락처에서 차단한 주소는 이 앱에서 풀 수 없다 (연락처 앱 > 설정 > 차단됨에서 푼다)
            Button(L("Apple 연락처에서 차단됨")) {}.disabled(true)
        } else if model.blockList.matches(address) {
            Button(L("연락처 차단 해제")) { Task { await model.unblock(address: address) } }
        } else {
            Button(L("연락처 차단")) { Task { await model.block(address: address) } }
        }
        Button(L("새로운 이메일")) {
            openWindow(id: "compose", value: ComposeDraft(to: recipient.emailAddress.mailAddress?.editable ?? address))
        }
        Divider()
        Button(L("이전 수신자 목록에서 제거")) { model.addressBook.remove(address) }
        Button(L("연락처 카드 보기")) { Task { await ContactCard.show(address: address, name: recipient.emailAddress.name) } }
        Divider()
        Button(L("'\(name)' 검색")) {
            model.searchScope = .all
            model.searchText = recipient.emailAddress.name?.isEmpty == false ? (recipient.emailAddress.name ?? address) : address
            Task { await model.loadMessages() }
        }
    }
}

/// 왼쪽부터 늘어놓다 폭이 차면 다음 줄로 넘기는 배치 (받는 사람 목록)
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// 대화 보기 (S-025): 대화의 메일을 오래된 순으로 한 줄씩. 누르면 아래에 그 메일이 펼쳐진다.
struct ThreadStrip: View {
    @Environment(AppModel.self) private var model
    /// 설정 > 보기 > "가장 최근 메시지를 맨 위에서 보기"
    @AppStorage(Prefs.threadNewestFirst) private var newestFirst = false
    /// 경계선을 끌어 바꾼 높이 (ThreadResizeHandle)
    @AppStorage(Prefs.threadHeight) private var height = Prefs.threadHeightDefault

    var body: some View {
        let rows = newestFirst ? Array(model.thread.reversed()) : model.thread
        let position = rows.firstIndex { $0.id == model.displayedMessageID }.map { $0 + 1 }
        VStack(alignment: .leading, spacing: 0) {
            // "대화 5통 중 3번째": 지금 보는 메일의 자리
            Text(position.map { L("대화 \(model.thread.count)통 중 \($0)번째") } ?? L("대화 \(model.thread.count)통"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xs)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(rows) { m in
                            ThreadRow(message: m, isShown: m.id == model.displayedMessageID,
                                      folderTag: model.folderTag(for: m), me: model.auth.email) {
                                model.showInThread(m.id)
                            }
                            .id(m.id)
                        }
                    }
                    .padding(.horizontal, Space.sm)
                }
                // 대화가 길어도 지금 보는 줄이 보이게 스크롤한다.
                .onAppear { if let id = model.displayedMessageID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.displayedMessageID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .frame(maxHeight: height)
        }
    }
}

/// 대화 목록과 본문 사이 경계선. 위아래로 끌면 대화 목록 높이가 바뀌고(기억한다), 두 번 누르면 기본 높이.
/// 보기 메뉴의 "대화 목록 늘리기·줄이기"(⌥⌘↓, ⌥⌘↑)와 같은 값을 쓴다.
struct ThreadResizeHandle: View {
    @AppStorage(Prefs.threadHeight) private var height = Prefs.threadHeightDefault
    @State private var dragStart: Double?

    var body: some View {
        Divider()
            .overlay {
                // 1pt 선은 잡기 어려우므로 위아래로 넓은 잡는 자리를 둔다.
                Color.clear
                    .frame(height: Space.sm)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .onTapGesture(count: 2) { height = Prefs.threadHeightDefault }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? height
                                dragStart = start
                                height = Prefs.clampThreadHeight(start + value.translation.height)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .help(L("끌어서 대화 목록 높이 조절, 두 번 누르면 기본 높이"))
            }
            .accessibilityElement()
            .accessibilityLabel(L("대화 목록 높이"))
            .accessibilityValue("\(Int(height))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: height = Prefs.clampThreadHeight(height + Prefs.threadHeightStep)
                case .decrement: height = Prefs.clampThreadHeight(height - Prefs.threadHeightStep)
                @unknown default: break
                }
            }
    }
}

struct ThreadRow: View {
    let message: MailMessage
    let isShown: Bool
    let folderTag: String?
    let me: String?
    let open: () -> Void

    private var sender: String {
        let address = message.from?.emailAddress.address?.lowercased()
        return address != nil && address == me?.lowercased() ? L("나") : (message.from?.emailAddress.display ?? "")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(sender)
                    .fontWeight(isShown || message.isUnread ? .semibold : .regular)
                    .foregroundStyle(isShown ? AnyShapeStyle(Palette.accentText) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                Text(message.bodyPreview ?? message.title)
                    .foregroundStyle(isShown ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                // 지금 보고 있는 메일: 강조색 꼬리표
                if isShown {
                    Label(L("보는 중"), systemImage: "eye.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(Palette.accent, in: Capsule())
                        .fixedSize()
                }
                if let folderTag {
                    Text(folderTag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs)
                        .background(.quaternary, in: Capsule())
                }
                Text(message.receivedDateTime.map { MailDate.listLabel($0) } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            // 줄 바깥 여백(Space.sm)과 합쳐 본문 머리글의 왼쪽 선(Space.margin)에 맞춘다.
            .padding(.leading, Space.margin - Space.sm + Space.xs)
            .padding(.trailing, Space.margin - Space.sm)
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
            // 지금 보고 있는 줄: 강조색 배경과 왼쪽의 굵은 막대
            .background {
                if isShown {
                    RoundedRectangle(cornerRadius: Space.sm, style: .continuous)
                        .fill(Palette.accentFill)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Palette.accent)
                                .frame(width: Space.xs)
                                .padding(.vertical, Space.xs)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .help(isShown ? L("지금 보고 있는 메일") : L("이 메일 펼치기"))
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }
}

/// 회의 초대 (S-038): 일시·장소와 수락 / 미정 / 거절
struct MeetingBar: View {
    let event: MailEvent
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.whenText())
                    .font(.callout.weight(.semibold))
                if let place = event.location?.displayName, !place.isEmpty {
                    Text(place)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // 서버가 기록한 내 응답 (보낸 뒤 다시 읽어 온 값)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Label(MeetingResponse.describe(event.responseStatus?.response),
                      systemImage: event.response == nil ? "questionmark.circle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // 맥 캘린더 (S-056): 넣었으면 그 결과, 아니면 직접 넣는 단추
            if let text = model.macCalendarStatus[event.id]?.label {
                Label(text, systemImage: "calendar.badge.checkmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button(L("맥 캘린더에 추가"), systemImage: "calendar.badge.plus") {
                    Task { await model.addMeetingToMacCalendar() }
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help(L("이 회의를 맥 캘린더에 넣습니다 (⌥⌘K)"))
            }
            // 응답 뒤 일정 확인 결과가 있으면 Outlook 웹 일정에서 바로 확인한다 (S-038)
            if let link = model.meetingCheck?.webLink {
                Button(L("일정에서 보기")) { NSWorkspace.shared.open(link) }
                    .controlSize(.small)
                    .help(model.meetingCheck?.summary ?? "")
            }
            ControlGroup {
                ForEach(MeetingResponse.allCases, id: \.self) { r in
                    Button(r.label) {
                        Task {
                            busy = true
                            await model.respondToMeeting(r)
                            busy = false
                        }
                    }
                    .disabled(busy || event.response == r)
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
        .background(.bar)
        // 이미 맥 캘린더에 있는 회의면 "있음" (S-056)
        .task(id: event.id) { model.loadMacCalendarStatus(for: event, subject: model.detail?.subject) }
    }
}
