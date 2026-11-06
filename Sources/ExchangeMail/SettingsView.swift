import AppKit
import ExchangeMailKit
import SwiftUI

/// The Settings window (Command-Comma), laid out like Mail's (S-048): one tab per topic, labels right-aligned
/// in the left column and controls in the right (`.formStyle(.columns)`). Signatures, rules, and auto reply
/// edit lists, so they keep their own layouts. Every tab has the same size (`SettingsView.size`).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    /// 모든 탭이 같은 크기: 탭을 바꿔도 창이 줄거나 늘지 않는다. 넘치면 탭 안에서 스크롤한다.
    static let size = CGSize(width: 880, height: 600)
    /// 탭 안쪽 여백: 좌우, 위아래
    static let marginX = Space.section
    static let marginY = Space.xxl

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .signatures, .account:
            // 왼쪽 목록 + 오른쪽 내용 (맥 Mail의 서명·계정 탭과 같은 틀)
            Group { if tab == .account { AccountSettings() } else { SignatureSettings() } }
                .padding(.horizontal, Self.marginX)
                .padding(.vertical, Self.marginY)
                .frame(width: Self.size.width, height: Self.size.height)
        case .rules, .autoReply:
            Form {
                if tab == .rules { RulesSettings() } else { AutoReplySettings() }
            }
            .formStyle(.grouped)
            // 목록 위아래에도 여백을 두어 첫 줄과 마지막 단추가 가장자리에 붙지 않게 한다.
            .contentMargins(.horizontal, Self.marginX - Space.xl, for: .scrollContent)
            .contentMargins(.vertical, Self.marginY - Space.sm, for: .scrollContent)
            .frame(width: Self.size.width, height: Self.size.height)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    switch tab {
                    case .general: GeneralSettings()
                    case .junk: JunkSettings()
                    case .fonts: FontSettings()
                    case .viewing: ViewingSettings()
                    case .composing: ComposingSettings()
                    case .notifications: NotificationSettings()
                    default: EmptyView()
                    }
                }
                // 모든 탭이 같은 너비의 레이블 열(오른쪽 정렬)과 왼쪽 맞춤 컨트롤 열을 쓴다.
                .labeledContentStyle(SettingsRowStyle())
                .padding(.horizontal, Self.marginX)
                .padding(.vertical, Self.marginY)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }
}

/// 설정 한 줄: 같은 너비의 레이블 열(오른쪽 정렬, 콜론) + 왼쪽 맞춤 컨트롤 열.
/// 탭마다 레이블 길이가 달라도 컨트롤이 같은 자리에서 시작한다.
struct SettingsRowStyle: LabeledContentStyle {
    static let labelWidth: CGFloat = 180

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            configuration.label
                .frame(width: Self.labelWidth, alignment: .trailing)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The Settings tabs, in Mail's order. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, account, junk, fonts, viewing, composing, signatures, rules, autoReply, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("일반")
        case .account: L("계정")
        case .junk: L("정크 메일")
        case .fonts: L("서체 및 색상")
        case .viewing: L("보기")
        case .composing: L("작성")
        case .signatures: L("서명")
        case .rules: L("규칙")
        case .autoReply: L("자동 응답")
        case .notifications: L("알림")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: "at"
        case .junk: "xmark.bin"
        case .fonts: "textformat.size"
        case .viewing: "eyeglasses"
        case .composing: "square.and.pencil"
        case .signatures: "signature"
        case .rules: "line.3.horizontal.decrease.circle"
        case .autoReply: "arrowshape.turn.up.backward.badge.clock"
        case .notifications: "bell.badge"
        }
    }
}

/// 설명 글: 오른쪽 열, 작고 흐리게
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 일반

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("refresh.minutes") private var refreshMinutes = 2
    @AppStorage("notify.badge") private var badge = true

    var body: some View {
        Section {
            DefaultMailAppSettings()
            LabeledContent(L("새 메일 확인:")) {
                Picker(L("새 메일 확인"), selection: $refreshMinutes) {
                    Text(L("1분마다")).tag(1)
                    Text(L("2분마다")).tag(2)
                    Text(L("5분마다")).tag(5)
                    Text(L("15분마다")).tag(15)
                    Text(L("수동")).tag(0)
                }
                    .labelsHidden()
            }
            .fixedSize()
            LabeledContent(L("Dock 배지:")) {
                Toggle(L("읽지 않은 메일 수 보이기"), isOn: $badge)
                    .onChange(of: badge) { _, _ in model.updateBadge() }
            }
        }
        OfflineSettings()
        AppearanceSettings()
        AppIconSettings()
    }
}

/// 설정 > 일반 > 오프라인 (S-026)
struct OfflineSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cache.enabled") private var enabled = true
    @AppStorage(Prefs.prefetch) private var prefetch = true
    @State private var size = 0

    var body: some View {
        Section {
            LabeledContent(L("오프라인:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("최근 메일을 이 Mac에 저장"), isOn: $enabled)
                        .onChange(of: enabled) { _, on in
                            if !on { clear() }
                        }
                    HStack(spacing: Space.sm) {
                        Text(L("저장된 메일 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button(L("지우기")) { clear() }
                            .controlSize(.small)
                            .disabled(size == 0)
                    }
                    SettingsNote(L("네트워크가 없을 때 최근 목록과 열어 본 메일을 보여 줍니다. 로그아웃하면 지웁니다."))
                }
            }
            LabeledContent(L("미리 받기:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("다음·이전 메일을 미리 받아 두기"), isOn: $prefetch)
                    SettingsNote(L("메일을 열면 목록의 다음 두 통과 이전 한 통을 미리 받아 ↓↑로 넘길 때 바로 보입니다. ")
                                 + L("끄면 서버 요청이 줄어듭니다."))
                }
            }
        }
        .task { size = model.cachedService?.cache?.sizeBytes() ?? 0 }
    }

    private func clear() {
        model.cachedService?.clearCache()
        size = 0
    }
}

// MARK: 계정

// MARK: 정크 메일

struct JunkSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent(L("걸러내기:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(L("Exchange Online이 서버에서 정크 메일을 걸러 정크 메일 폴더로 옮깁니다."))
                    SettingsNote(L("차단한 보낸 사람과 안전한 보낸 사람 목록은 Outlook 웹에서 관리합니다. 이 Mac과 다른 기기에 모두 적용됩니다."))
                    Button(L("Outlook 웹 정크 메일 설정 열기…")) {
                        if let url = URL(string: "https://outlook.office.com/mail/options/mail/junkEmail") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            LabeledContent(L("정크로 표시:")) {
                SettingsNote(L("메시지 > 정크 메일로 표시(⇧⌘J)는 메일을 정크 메일 폴더로 옮겨 Exchange가 배우게 합니다. ")
                             + L("정크 메일 폴더에서는 같은 메뉴가 \"정크 아님\"이 되어 받은 편지함으로 돌려놓습니다."))
            }
        }
        Section {
            LabeledContent(L("정크 메일 폴더:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("원격 그림을 항상 막기"), isOn: $model.junkBlocksRemote)
                    SettingsNote(L("메일 활동 보호를 켜 두어도 정크 메일의 원격 그림은 받지 않습니다."))
                }
            }
        }
        BlockedSettings()
    }
}

/// 설정 > 정크 메일 > 차단됨: 받은 편지함 서버 규칙 하나로 관리한다 (앱이 꺼져 있어도 적용).
struct BlockedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newAddress = ""
    @State private var busy = false

    var body: some View {
        Section {
            LabeledContent(L("차단된 보낸 사람:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("차단된 메일 필터링 사용"), isOn: Binding(
                        get: { model.blockEnabled },
                        set: { on in save(model.blockedAddresses, model.blockMode, on) }))
                        .disabled(busy || model.blockedAddresses.isEmpty)
                    Text(L("차단된 주소에서 메일이 오면:"))
                    Picker(L("차단된 주소에서 메일이 오면"), selection: Binding(
                        get: { model.blockMode },
                        set: { mode in save(model.blockedAddresses, mode, model.blockEnabled) })) {
                        Text(L("차단됨 범주를 붙이고 받은 편지함에 두기")).tag(BlockedSenders.Mode.keep)
                        Text(L("지운 편지함으로 이동")).tag(BlockedSenders.Mode.trash)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(busy || model.blockedAddresses.isEmpty)
                    if model.blockedAddresses.isEmpty {
                        SettingsNote(model.blockedLoaded ? L("차단한 보낸 사람이 없습니다. 메일을 오른쪽 클릭해 \"보낸 사람 차단\"을 고르거나 아래에 주소를 넣으세요.")
                                                         : L("불러오는 중…"))
                    } else {
                        ForEach(model.blockedAddresses, id: \.self) { address in
                            HStack(spacing: Space.sm) {
                                Text(address)
                                    .textSelection(.enabled)
                                Button(L("차단 해제"), systemImage: "minus.circle") {
                                    busy = true
                                    Task {
                                        await model.unblock(address: address)
                                        busy = false
                                    }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help(L("\(address) 차단 해제"))
                                .disabled(busy)
                            }
                        }
                    }
                    HStack(spacing: Space.sm) {
                        TextField(L("주소"), text: $newAddress, prompt: Text("spam@example.com"))
                            .frame(maxWidth: 240)
                            .onSubmit { add() }
                        Button(L("차단")) { add() }
                            .disabled(busy || !newAddress.contains("@"))
                        if busy { ProgressView().controlSize(.small) }
                    }
                    SettingsNote(L("받은 편지함 규칙 \"\(BlockedSenders.ruleName)\"으로 저장됩니다. Outlook 웹과 다른 기기에도 적용됩니다."))
                }
            }
        }
        .task { await model.loadBlocked() }
    }

    private func add() {
        let address = newAddress.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { return }
        busy = true
        Task {
            await model.block(address: address)
            newAddress = ""
            busy = false
        }
    }

    private func save(_ addresses: [String], _ mode: BlockedSenders.Mode, _ enabled: Bool) {
        busy = true
        Task {
            await model.saveBlocked(addresses: addresses, mode: mode, enabled: enabled)
            busy = false
        }
    }
}

// MARK: 서체 및 색상

struct FontSettings: View {
    @AppStorage(Prefs.listFontSize) private var listSize = 13
    @AppStorage(Prefs.bodyFontFamily) private var family = ""
    @AppStorage(Prefs.bodyFontSize) private var bodySize = 14
    @AppStorage(Prefs.plainMonospace) private var plainMonospace = false
    @AppStorage(Prefs.quoteColors) private var quoteColors = true
    @AppStorage(Prefs.quoteColor1) private var quote1 = Prefs.defaultQuoteColors[0]
    @AppStorage(Prefs.quoteColor2) private var quote2 = Prefs.defaultQuoteColors[1]
    @AppStorage(Prefs.quoteColor3) private var quote3 = Prefs.defaultQuoteColors[2]

    private let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Section {
            LabeledContent(L("메시지 목록 글자 크기:")) {
                Picker(L("메시지 목록 글자 크기"), selection: $listSize) {
                    ForEach([11, 12, 13, 14, 15, 16, 18], id: \.self) { Text("\($0)").tag($0) }
                }
                    .labelsHidden()
            }
            .fixedSize()
            LabeledContent(L("메시지 서체:")) {
                HStack(spacing: Space.sm) {
                    Picker(L("서체"), selection: $family) {
                        Text(L("시스템 서체")).tag("")
                        Divider()
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    Picker(L("크기"), selection: $bodySize) {
                        ForEach([12, 13, 14, 15, 16, 18, 20], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            LabeledContent(L("일반 텍스트:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("일반 텍스트 메시지에 고정폭 서체 사용"), isOn: $plainMonospace)
                    SettingsNote(L("HTML 메일은 보낸 사람이 정한 서체가 먼저 쓰입니다."))
                }
            }
        }
        Section {
            LabeledContent(L("인용 텍스트:")) {
                VStack(alignment: .leading, spacing: Space.md) {
                    Toggle(L("인용 텍스트 색상"), isOn: $quoteColors)
                    HStack(alignment: .top, spacing: Space.xl) {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            colorRow(L("1단계"), $quote1)
                            colorRow(L("2단계"), $quote2)
                            colorRow(L("3단계"), $quote3)
                        }
                        preview
                    }
                    .disabled(!quoteColors)
                    Button(L("기본 색으로")) {
                        quote1 = Prefs.defaultQuoteColors[0]
                        quote2 = Prefs.defaultQuoteColors[1]
                        quote3 = Prefs.defaultQuoteColors[2]
                    }
                    .disabled(!quoteColors)
                }
            }
        }
    }

    private func colorRow(_ title: String, _ hex: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(hex: hex.wrappedValue) ?? .secondary },
                                              set: { hex.wrappedValue = $0.hexString }),
                    supportsOpacity: false)
    }

    /// 인용 단계 미리보기: 단계마다 왼쪽 막대와 글자색
    private var preview: some View {
        let colors = [quote1, quote2, quote3].map { quoteColors ? (Color(hex: $0) ?? .secondary) : Color.secondary }
        return HStack(alignment: .top, spacing: Space.sm) {
            Rectangle().fill(colors[0]).frame(width: 2)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(L("1단계")).foregroundStyle(colors[0])
                HStack(alignment: .top, spacing: Space.sm) {
                    Rectangle().fill(colors[1]).frame(width: 2)
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(L("2단계")).foregroundStyle(colors[1])
                        HStack(spacing: Space.sm) {
                            Rectangle().fill(colors[2]).frame(width: 2)
                            Text(L("3단계")).foregroundStyle(colors[2])
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Space.md)
        .frame(width: 200, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Space.xs).strokeBorder(.separator))
        .accessibilityLabel(L("인용 단계 색 미리보기"))
    }
}

// MARK: 보기

struct ViewingSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("list.threaded") private var threaded = true
    @AppStorage(Prefs.previewLines) private var previewLines = 2
    @AppStorage(Prefs.boldUnread) private var boldUnread = true
    @AppStorage(Prefs.selectNextAfterMove) private var selectNext = true
    @AppStorage(Prefs.markRead) private var markRead = "now"
    @AppStorage(Prefs.threadAllFolders) private var threadAllFolders = true
    @AppStorage(Prefs.threadNewestFirst) private var threadNewestFirst = false
    @AppStorage(Prefs.swipeRight) private var swipeRight = SwipeAction.read
    @AppStorage(Prefs.swipeLeft) private var swipeLeft = SwipeAction.delete
    @AppStorage(Prefs.swipeLeftMore) private var swipeLeftMore = true

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent(L("목록:")) {
                Toggle(L("대화별로 정리"), isOn: $threaded)
            }
            LabeledContent(L("정렬 기준:")) {
                Picker(L("정렬 기준"), selection: $model.listSort.key) {
                    ForEach(MailSort.Key.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                    .labelsHidden()
            }
            .fixedSize()
            LabeledContent(L("순서:")) {
                Picker(L("순서"), selection: $model.listSort.descending) {
                    Text(model.listSort.key == .date ? L("새로운 항목 우선") : L("내림차순")).tag(true)
                    Text(model.listSort.key == .date ? L("오래된 항목 우선") : L("오름차순")).tag(false)
                }
                    .labelsHidden()
            }
            .fixedSize()
        }
        Section {
            LabeledContent(L("목록 미리보기:")) {
                Picker(L("목록 미리보기"), selection: $previewLines) {
                    Text(L("없음")).tag(0)
                    ForEach(1...5, id: \.self) { Text(L("\($0)줄")).tag($0) }
                }
                    .labelsHidden()
            }
            .fixedSize()
            LabeledContent(L("목록:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("볼드체로 읽지 않은 메시지 표시"), isOn: $boldUnread)
                    Toggle(L("메시지를 지우거나 보관한 후 자동으로 다음 메시지 보기"), isOn: $selectNext)
                }
            }
            LabeledContent(L("'읽음으로 표시' 동작:")) {
                Picker(L("'읽음으로 표시' 동작"), selection: $markRead) {
                    Text(L("메시지를 열면 바로")).tag("now")
                    Text(L("5초 동안 보고 있으면")).tag("delay")
                    Text(L("직접 표시할 때만")).tag("never")
                }
                    .labelsHidden()
            }
            .fixedSize()
        }
        Section {
            LabeledContent(L("오른쪽으로 쓸기:")) {
                Picker(L("오른쪽으로 쓸기"), selection: $swipeRight) {
                    ForEach(SwipeAction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent(L("왼쪽으로 쓸기:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Picker(L("왼쪽으로 쓸기"), selection: $swipeLeft) {
                        ForEach(SwipeAction.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Toggle(L("다른 동작 단추도 함께 보이기"), isOn: $swipeLeftMore)
                        .disabled(swipeLeft == .none)
                    SettingsNote(L("메일 목록의 줄을 트랙패드 두 손가락(또는 Magic Mouse 한 손가락)으로 좌우로 쓸 때 하는 일입니다. ")
                                 + L("끝까지 쓸면 고른 동작을 바로 합니다. 지우기와 보관은 ⌘Z로 되돌릴 수 있습니다."))
                }
            }
        }
        Section {
            LabeledContent(L("대화 보기:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("관련된 메시지 포함"), isOn: $threadAllFolders)
                    SettingsNote(L("끄면 대화에 지금 폴더의 메일만 보입니다. 켜면 보낸 편지함 같은 다른 폴더의 답장도 함께 보입니다."))
                    Toggle(L("가장 최근 메시지를 맨 위에서 보기"), isOn: $threadNewestFirst)
                }
            }
        }
        Section {
            LabeledContent(L("개인정보 보호:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("메일 활동 보호"), isOn: $model.protectMailActivity)
                    SettingsNote(L("추적 픽셀과 알려진 추적 서비스를 막고, 나머지 원격 그림은 앱이 쿠키·리퍼러 없이 대신 받아 ")
                                 + L("보여 줍니다. 보낸 사람은 메일을 언제 열었는지 알 수 없습니다. ")
                                 + L("IP 주소는 숨기지 않습니다(중계 서버가 필요해서)."))
                    Toggle(L("모든 원격 콘텐츠 차단"), isOn: $model.blockAllRemote)
                        .disabled(model.protectMailActivity)
                        .padding(.top, Space.sm)
                    SettingsNote(L("메일 활동 보호를 끈 경우에만 씁니다. 켜면 원격 그림을 받지 않고, 메일마다 \"불러오기\"로 볼 수 있습니다."))
                }
            }
        }
    }
}

// MARK: 작성

struct ComposingSettings: View {
    @AppStorage(Prefs.spellcheck) private var spellcheck = true
    @AppStorage(Prefs.autoIncludeMe) private var autoIncludeMe = "none"
    @AppStorage(Prefs.highlightExternal) private var highlightExternal = false
    @AppStorage(Prefs.internalDomains) private var internalDomains = ""
    @AppStorage(Prefs.quoteOriginal) private var quoteOriginal = true
    @AppStorage("send.undoDelay") private var undoDelay = 10
    @AppStorage("fixEnabled") private var fixEnabled = true
    @AppStorage("fixImagesAsAttachments") private var images = true
    @AppStorage("fixEUCKR") private var eucKR = false
    @AppStorage("fixMinKB") private var minKB = 0

    var body: some View {
        Section {
            LabeledContent(L("맞춤법 검사:")) {
                Picker(L("맞춤법 검사"), selection: $spellcheck) {
                    Text(L("입력할 때")).tag(true)
                    Text(L("안 함")).tag(false)
                }
                    .labelsHidden()
            }
            .fixedSize()
            LabeledContent(L("자동으로 나를 포함:")) {
                Picker(L("자동으로 나를 포함"), selection: $autoIncludeMe) {
                    Text(L("안 함")).tag("none")
                    Text(L("참조에")).tag("cc")
                    Text(L("숨은 참조에")).tag("bcc")
                }
                    .labelsHidden()
            }
            .fixedSize()
        }
        Section {
            LabeledContent(L("주소:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("다음으로 끝나지 않는 주소 표시"), isOn: $highlightExternal)
                    TextField(L("도메인"), text: $internalDomains, prompt: Text("@example.com, @example.co.kr"))
                        .frame(maxWidth: 320)
                        .disabled(!highlightExternal)
                    SettingsNote(L("작성 창에서 이 도메인 밖의 받는 사람을 주황색으로 알려 줍니다. 회사 밖으로 잘못 보내는 일을 막습니다."))
                }
            }
            LabeledContent(L("답장:")) {
                Toggle(L("원본 메시지의 텍스트를 인용"), isOn: $quoteOriginal)
            }
        }
        Section {
            LabeledContent(L("보내기 취소:")) {
                Picker(L("보내기 취소"), selection: $undoDelay) {
                    Text(L("끔")).tag(0)
                    Text(L("5초")).tag(5)
                    Text(L("10초")).tag(10)
                    Text(L("20초")).tag(20)
                }
                    .labelsHidden()
            }
            .fixedSize()
            LabeledContent("") {
                SettingsNote(L("보내기를 누른 뒤 이 시간 동안 작성 창에서 \"보내기 취소\"를 누를 수 있습니다."))
            }
        }
        Section {
            LabeledContent(L("첨부 보정:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("새 메일에 첨부 보정 켜기"), isOn: $fixEnabled)
                    Toggle(L("본문 그림을 일반 첨부파일로 보내기"), isOn: $images)
                    Stepper(value: $minKB, in: 0...2048, step: 10) {
                        Text(minKB == 0 ? L("모든 그림을 첨부로") : L("\(minKB) KB보다 작은 그림은 본문에 두기"))
                    }
                    .disabled(!images)
                    Toggle(L("EUC-KR 파일명 (구형 국내 시스템용)"), isOn: $eucKR)
                    SettingsNote(L("모든 새 메일에 적용됩니다. EUC-KR로 쓸 수 없는 글자가 있으면 UTF-8로 보냅니다."))
                }
            }
            LabeledContent(L("항상 적용:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label(L("한글 파일명을 완성형(NFC)으로 바꿉니다."), systemImage: "textformat")
                    Label(L("파일명을 RFC 2047과 RFC 2231로 함께 기록해 Windows·Outlook에서도 한글로 보입니다."), systemImage: "doc.text")
                    Label(L("서명과 인용문 안의 그림은 본문에 그대로 둡니다."), systemImage: "signature")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: 알림 (S-024)

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("notify.newMail") private var newMail = true
    @AppStorage("notify.sound") private var sound = true

    var body: some View {
        Section {
            LabeledContent(L("새 메일:")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(L("받은 편지함에 새 메일이 오면 알리기"), isOn: $newMail)
                        .onChange(of: newMail) { _, on in
                            if on { Task { await model.prepareNotifications() } }
                        }
                    Toggle(L("알림 소리"), isOn: $sound)
                        .disabled(!newMail)
                    if newMail && model.notificationPermission == .denied {
                        HStack(spacing: Space.sm) {
                            Label(L("macOS 알림 권한이 꺼져 있습니다."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Button(L("시스템 설정 열기")) { openSystemSettings() }
                                .controlSize(.small)
                        }
                    }
                    SettingsNote(L("설정 > 일반의 간격마다 확인합니다. 앱이 앞에 있으면 배너 없이 알림 센터에만 남습니다."))
                }
            }
        }
        .task { await model.refreshNotificationPermission() }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
