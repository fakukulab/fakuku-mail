import AppKit
import ExchangeMailKit
import Observation
import SwiftUI

enum SearchScope: Hashable {
    case folder, all
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    /// 계정들 (M23). 계정마다 로그인과 메일 서비스가 따로 있다.
    let accounts: AccountStore
    /// 계정에 요청을 나눠 주는 안내자. `service`와 같은 것.
    @ObservationIgnored let router: AccountRouter
    /// 지금 계정의 로그인 (계정이 없으면 새 계정용 로그인). 이름·주소를 읽는 곳이 많아 예전 이름을 그대로 쓴다.
    var auth: GraphAuth { accounts.active?.auth ?? accounts.pending }
    let signatures: SignatureStore
    let addressBook: AddressBookStore
    /// 새 메일 알림과 Dock 배지 (S-024)
    @ObservationIgnored let notifier: any MailNotifier
    var notificationPermission = NotifyPermission.notAsked
    /// 계정마다 새 메일 기준 (주소 → 기준). AppModel+Notifications
    @ObservationIgnored var trackers: [String: NewMailTracker] = [:]
    /// 알림을 눌러 열 메일. 받은 편지함 목록이 오면 고른다.
    @ObservationIgnored var pendingOpenID: String?
    let isDemo: Bool
    @ObservationIgnored let service: any MailService
    /// 본문 웹 보기 넘기기 (S-019)
    @ObservationIgnored let pageScroller = PageScroller()

    // 폴더
    /// 지금 계정의 폴더 (받은 편지함 찾기, 이동 대상, 폴더 꼬리표)
    var folders: [MailFolder] = []
    /// 계정마다의 폴더 (사이드바)
    var accountFolders: [String: [MailFolder]] = [:]
    var selectedFolderID: String? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            // 다른 계정의 폴더를 고르면 그 계정이 지금 계정이 된다 (M23)
            if let id = selectedFolderID, !VirtualMailbox.isVirtual(id), LocalMailbox.id(fromSidebar: id) == nil {
                activateAccount(router.accountID(forFolder: id))
            }
            searchText = ""
            threadCounts = [:]
            updateMenu()
            Task { await loadMessages() }
        }
    }

    // 목록
    var messages: [MailMessage] = []
    private(set) var nextLink: String?
    var searchText = ""
    private(set) var isLoading = false
    private(set) var isLoadingMore = false

    /// 목록에서 고른 줄들 (S-027). 한 줄이면 `selectedMessageID`와 같고, 여러 줄이면 본문은 비운다.
    var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            let single = selection.count == 1 ? selection.first : nil
            if selectedMessageID != single { selectedMessageID = single }
            updateMenu()
        }
    }
    /// 메시지 > 이동… 시트 (S-028)
    var showMovePicker = false
    /// 메일상자 > 메일 검색(⌥⌘F)을 누를 때마다 늘어난다. 검색 칸이 보고 초점을 받는다.
    var searchFocusRequest = 0
    /// 마지막으로 옮긴 폴더 (메시지 > 'X'(으)로 다시 이동, ⌃⌘M). 보관·지우기·정크는 넣지 않는다.
    var lastMoveTarget: MoveTarget? {
        didSet { updateMenu() }
    }
    /// 알림을 끈 대화 (메시지 > 알림 비활성화). 이 Mac에 저장한다.
    var mutedConversations: Set<String> = AppModel.savedMuted() {
        didSet {
            if !Store.isOverridden { UserDefaults.standard.set(Array(mutedConversations), forKey: "muted.conversations") }
            updateMenu()
        }
    }
    /// 메일마다 깃발 색 (열쇠: Internet Message-ID). 이 Mac에만 저장한다.
    var flagColors: [String: FlagColor] = AppModel.savedFlagColors() {
        didSet {
            guard !Store.isOverridden else { return }
            UserDefaults.standard.set(flagColors.mapValues(\.rawValue), forKey: "flag.colors")
        }
    }

    static func savedFlagColors() -> [String: FlagColor] {
        guard !Store.isOverridden,
              let raw = UserDefaults.standard.dictionary(forKey: "flag.colors") as? [String: String] else { return [:] }
        return raw.compactMapValues(FlagColor.init(rawValue:))
    }

    /// 지운 편지함 비우기 같은 오래 걸리는 일의 진행 글 (목록 위 막대)
    var progressText: String?
    /// 메일상자 내보내기 중 (S-053)
    var archiveExporting = false { didSet { updateMenu() } }
    /// 나의 Mac에 (S-055): 가져온 메일상자. 로그아웃해도 남는다.
    /// 회의마다 맥 캘린더에 넣은 결과 (S-056, 회의 막대에 보인다)
    var macCalendarStatus: [String: MacCalendar.Outcome] = [:]
    /// 열려던 메일이 서버에 없었다 (다른 기기·규칙이 옮겼거나 지웠다). 본문 열에 짧게 알린다.
    var missingMessageNotice = false
    @ObservationIgnored var lastNotFoundRefresh: Date?
    /// 대화 묶음 결과 (AppModel+Conversations.conversations)
    @ObservationIgnored var conversationMemo: (key: Int, value: [Conversation])?
    /// 열어 본 메일과 미리 받은 메일 (AppModel+Prefetch)
    @ObservationIgnored let detailCache = DetailCache()
    /// 미리 받기 (다른 메일을 열면 앞의 것을 그만둔다)
    @ObservationIgnored var prefetchTask: Task<Void, Never>?
    /// 대화별 메일과 받은 시각 (1분 동안 다시 묻지 않는다)
    @ObservationIgnored var threadCache: [String: (at: Date, list: [MailMessage])] = [:] {
        // 옮기기·지우기 등으로 비우면 목록 줄의 확인된 수도 다시 센다.
        didSet { if threadCache.isEmpty && !threadCounts.isEmpty { threadCounts = [:] } }
    }
    /// 대화를 열어 서버에서 확인한 메일 수 (목록 줄 id → 수). 목록 줄은 이 수를 먼저 쓴다.
    var threadCounts: [String: Int] = [:]
    /// 모든 폴더 검색에서 찾은 나의 Mac에 메일 (서버 결과 아래에 보인다)
    var localHits: [LocalHit] = []
    let localBoxes = LocalMailboxStore(directory: Store.directory.appending(path: "local", directoryHint: .isDirectory))
    @ObservationIgnored var exportTask: Task<Void, Never>?
    /// 차단된 보낸 사람 서버 규칙 (설정 > 정크 메일). 아직 읽지 않았으면 nil.
    var blockedRule: MessageRule?
    var blockedLoaded = false

    static func savedMuted() -> Set<String> {
        guard !Store.isOverridden else { return [] }
        return Set(UserDefaults.standard.stringArray(forKey: "muted.conversations") ?? [])
    }
    /// 검색 범위 (S-033). 바꾸면 검색어가 있을 때 다시 찾는다.
    var searchScope = SearchScope.folder {
        didSet {
            guard searchScope != oldValue, !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task { await loadMessages() }
        }
    }
    /// 목록 필터 (S-041). 바꾸면 다시 불러온다. 폴더를 옮겨도 해제할 때까지 남는다.
    var listFilter = MailFilter() {
        didSet {
            guard listFilter != oldValue else { return }
            updateMenu()
            Task { await loadMessages(keepSelection: true) }
        }
    }
    /// 정렬 기준 (S-042). 앱을 다시 열어도 남는다. 날짜 방향이 바뀔 때만 서버에서 다시 받는다.
    var listSort = AppModel.savedSort() {
        didSet {
            guard listSort != oldValue else { return }
            if let data = try? JSONEncoder().encode(listSort), !Store.isOverridden {
                UserDefaults.standard.set(data, forKey: "list.sort")
            }
            if listSort.serverOldestFirst != oldValue.serverOldestFirst {
                Task { await loadMessages(keepSelection: true) }
            } else {
                messages = listSort.apply(messages)
            }
            updateMenu()
        }
    }
    /// Outlook 범주 이름 (필터 메뉴)
    var categories: [String] = []
    /// VIP와 스마트 메일상자 (S-045, S-046)
    let mailboxes = MailboxStore(url: Store.directory.appending(path: "mailboxes.json"))
    /// 개별 발송 템플릿·그룹과 실행기 (M18)
    let merge = MergeStore(url: Store.directory.appending(path: "merge.json"))
    let mergeSender = MergeSender()
    /// 열린 VIP 편집 시트 (이름·아이콘)
    var editingVIP: VIP?
    /// 열린 스마트 메일상자 편집 시트
    var editingSmart: SmartMailbox?

    // 개인정보 보호 (S-047). 설정 > 보기, 설정 > 정크 메일. 테스트·스냅숏은 저장하지 않는다.
    /// 메일 활동 보호: 추적기를 막고 원격 그림은 앱이 대신 받는다
    var protectMailActivity = AppModel.savedFlag("privacy.protect", default: true) {
        didSet { saveFlag("privacy.protect", protectMailActivity); updateMenu() }
    }
    /// 메일 활동 보호를 끈 경우: 원격 콘텐츠를 막을지
    var blockAllRemote = AppModel.savedFlag("privacy.blockAll", default: true) {
        didSet { saveFlag("privacy.blockAll", blockAllRemote); updateMenu() }
    }
    /// 정크 메일 폴더의 원격 그림은 항상 막기
    var junkBlocksRemote = AppModel.savedFlag("junk.blockRemote", default: true) {
        didSet { saveFlag("junk.blockRemote", junkBlocksRemote); updateMenu() }
    }
    /// 본문 문서 캐시: 추적기 바꾸기는 정규식이라 같은 메일을 다시 그릴 때마다 하지 않는다.
    @ObservationIgnored var pageCache: [String: ProtectedPage] = [:]
    @ObservationIgnored var remoteContentMemo: (key: String, value: Bool)?

    static func savedFlag(_ key: String, default value: Bool) -> Bool {
        guard !Store.isOverridden, UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.bool(forKey: key)
    }

    func saveFlag(_ key: String, _ value: Bool) {
        if !Store.isOverridden { UserDefaults.standard.set(value, forKey: key) }
    }

    static func savedSort() -> MailSort {
        guard !Store.isOverridden, let data = UserDefaults.standard.data(forKey: "list.sort"),
              let sort = try? JSONDecoder().decode(MailSort.self, from: data) else { return MailSort() }
        return sort
    }

    /// Quick Look으로 보는 첨부 파일 (S-032)
    var previewURL: URL?
    /// 인쇄가 끝날 때까지 잡아 둔다 (S-034)
    @ObservationIgnored var printer: MailPrinter?

    // 본문
    var selectedMessageID: String? {
        didSet {
            guard selectedMessageID != oldValue else { return }
            // 목록 선택과 맞춘다: 한 통을 고르면 그 줄만, 비우면(여러 줄이 아닐 때) 선택도 비운다.
            if let id = selectedMessageID {
                if selection != [id] { selection = [id] }
            } else if selection.count == 1 {
                selection = []
            }
            allowRemoteFor = nil
            shownMessageID = nil
            if selectedMessageID != nil { missingMessageNotice = false }
            // 같은 대화 안에서 옮기면 대화 목록을 비우지 않는다 (깜빡이지 않게). 다른 대화면 비운다.
            let newConversation = selectedMessageID.flatMap { id in messages.first { $0.id == id }?.conversationId }
            if newConversation == nil || !thread.contains(where: { $0.conversationId == newConversation }) {
                thread = []
            }
            // 기억해 둔 메일은 기다리지 않고 바로 바꿔 보인다 (한 프레임도 비지 않게).
            showCachedDetail()
            updateMenu()
            // 본문과 대화를 동시에 불러온다 (대화가 본문을 기다리지 않게).
            Task { await loadDetail() }
            Task { await loadThread() }
        }
    }
    /// 대화 보기에서 펼친 메일 (S-025). nil이면 목록에서 고른 메일.
    private(set) var shownMessageID: String?
    /// 고른 메일의 대화 전체, 오래된 순 (S-025). 대화가 아니면 비어 있다.
    var thread: [MailMessage] = []
    /// 본문에 보이는 메일 id
    var displayedMessageID: String? { shownMessageID ?? selectedMessageID }
    private(set) var detail: MailMessage?
    /// 인라인 첨부까지 모두. 목록에 보일 첨부는 `listedAttachments`.
    private(set) var detailAttachments: [FileAttachment] = []
    /// cid 그림을 data: URI로 바꾼 본문
    private(set) var detailBody: MailMessage.Body?
    /// 원격 이미지를 허용한 메시지 id (다른 메시지로 옮기면 다시 차단)
    private(set) var allowRemoteFor: String?

    var errorMessage: String?
    /// 오류가 아닌 알림 (구독 취소 완료 등)
    var noticeMessage: String?
    /// 마지막 회의 응답 뒤 일정 확인 결과 (회의 막대의 '일정에서 보기')
    var meetingCheck: MeetingCheck?
    /// Siri·단축어가 연 새 메일 (ContentView가 작성 창을 연다)
    var pendingCompose: ComposeDraft?
    /// 대화별로 정리할 때 함께 세는 다른 폴더의 메일 (받은 편지함이면 보낸 편지함, 보낸 편지함이면 받은 편지함)
    var relatedMessages: [MailMessage] = []
    /// 스냅숏에서 로그인 화면을 찍을 때만 켠다.
    var previewSignIn = false

    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    init(accounts: AccountStore, signatures: SignatureStore, addressBook: AddressBookStore,
         notifier: any MailNotifier, isDemo: Bool) {
        self.addressBook = addressBook
        self.notifier = notifier
        self.accounts = accounts
        let router = AccountRouter(store: accounts)
        self.router = router
        self.signatures = signatures
        self.service = router
        self.isDemo = isDemo
    }

    static func make() -> AppModel {
        let signatures = SignatureStore(url: Store.directory.appending(path: "signatures.json"))
        let addressBook = AddressBookStore(url: Store.directory.appending(path: "recipients.json"))
        if Store.isDemo, signatures.signatures.isEmpty { DemoMailService.seedSignatures(into: signatures) }
        // 계정마다 메일 서비스: Graph(데모면 예시 사서함) + 오프라인 캐시(S-026, 계정 주소별 폴더).
        let box = ModelBox()
        let makeService: (GraphAuth, IMAPAccountConfig?) -> CachedMailService = { auth, imap in
            let remote: any MailService
            if Store.isDemo {
                remote = DemoMailService()
            } else if let imap {
                // iCloud·Gmail (M24): 앱 암호는 키체인에
                let imapService = IMAPMailService(accountID: auth.accountKey, config: imap,
                                                  password: AccountStore.password(for: auth.accountKey))
                imapService.warmUp()
                remote = imapService
            } else {
                remote = GraphMailService(auth: auth)
            }
            let cached = CachedMailService(remote: remote, base: Store.directory.appending(path: "cache", directoryHint: .isDirectory),
                                           account: { auth.email }, enabled: { AppModel.cacheEnabled })
            cached.onOfflineChange = { offline in box.model?.isOffline = offline }
            return cached
        }
        let accounts = AccountStore(demoEmail: Store.isDemo ? DemoMailService.myAddress : nil, makeService: makeService)
        let model = AppModel(accounts: accounts, signatures: signatures, addressBook: addressBook,
                             notifier: Store.isDemo ? RecordingNotifier() : SystemNotifier.shared, isDemo: Store.isDemo)
        box.model = model
        return model
    }

    // MARK: 오프라인 (S-026)

    /// 네트워크가 없어 저장된 메일을 보여 주는 중
    var isOffline = false
    static var cacheEnabled: Bool { UserDefaults.standard.object(forKey: "cache.enabled") as? Bool ?? true }
    /// 지금 계정의 메일 서비스 (오프라인 캐시)
    var cachedService: CachedMailService? { accounts.active?.service }
    /// 데모 사서함 (스냅숏, 셀프 테스트)
    var demoService: DemoMailService? { (cachedService?.remote ?? service) as? DemoMailService }

    /// 오프라인 막대의 "다시 연결"
    func retryConnection() async {
        if await cachedService?.retry() == true { await refresh() }
    }

    /// 로그아웃: 지금 계정을 뺀다 (이 Mac에 저장한 그 계정의 메일도 지운다).
    func signOut() {
        guard let id = accounts.active?.id else { return }
        signOut(accountID: id)
    }

    /// 계정 하나를 뺀다. 다른 계정이 남아 있으면 그 계정으로 다시 불러온다.
    func signOut(accountID id: String) {
        accounts.remove(id)
        accountFolders[id] = nil
        if accounts.accounts.isEmpty { return }
        selectedFolderID = nil
        Task { await reloadAll() }
    }

    /// 계정 추가 (로그인 화면, 설정 > 계정): Microsoft 로그인 창으로 로그인해 계정을 더하고 그 계정의 폴더를 불러온다.
    func addAccount(email: String? = nil) async {
        guard let account = await accounts.addAccount(email: email) else { return }
        if accounts.accounts.count > 1 {
            await loadFolders()
            selectedFolderID = accountFolders[account.id]?.first { $0.kind == "inbox" }?.id ?? selectedFolderID
        }
    }

    /// iCloud·Gmail 계정 추가 (설정 > 계정 > +, M24). 앱 암호가 틀리면 오류를 던진다.
    func addIMAPAccount(_ config: IMAPAccountConfig, password: String) async throws {
        let account = try await accounts.addIMAPAccount(config, password: password)
        await loadFolders()
        selectedFolderID = accountFolders[account.id]?.first { $0.kind == "inbox" }?.id ?? selectedFolderID
    }

    var isSignedIn: Bool { isDemo || !accounts.accounts.isEmpty }
    var showsMail: Bool { isSignedIn && !previewSignIn }

    var selectedFolder: MailFolder? { folders.first { $0.id == selectedFolderID } }
    var selectedMessage: MailMessage? { messages.first { $0.id == selectedMessageID } }
    var listedAttachments: [FileAttachment] { detailAttachments.filter(\.isListed) }

    /// 본문에 원격 그림이 있는가. 정규식 여러 개로 본문 전체를 훑으므로 메일마다 한 번만 계산한다
    /// (창 크기를 바꾸는 동안 본문 열이 계속 다시 그려진다).
    var detailHasRemoteContent: Bool {
        guard let body = detailBody, body.isHTML else { return false }
        let key = "\(detail?.id ?? "")|\(body.content.utf8.count)"
        if let memo = remoteContentMemo, memo.key == key { return memo.value }
        let value = MailContent.hasRemoteContent(body.content)
        remoteContentMemo = (key, value)
        return value
    }
    /// 고른 메일의 본문을 아직 받는 중 (지금 보이는 것은 이전 메일). 본문 위 진행 막대가 쓴다.
    var isLoadingDetail: Bool {
        guard let shown = displayedMessageID, multipleSelectionCount == 0 else { return false }
        return detail?.id != shown
    }
    var remoteContentAllowed: Bool { detail != nil && allowRemoteFor == detail?.id }

    // MARK: 불러오기

    /// 폴더와 목록을 처음부터 불러온다 (로그인 직후).
    func reloadAll() async {
        guard isSignedIn else {
            folders = []; messages = []; detail = nil; accountFolders = [:]
            detailCache.removeAll(); threadCache = [:]
            // 로그아웃: 배지를 지우고, 다음 계정은 새 기준으로 시작한다.
            trackers = [:]
            updateBadge()
            updateMenu()
            return
        }
        await loadFolders()
        categories = (try? await service.categories()) ?? []
        if selectedFolderID == nil
            || (!folders.contains(where: { $0.id == selectedFolderID }) && selectedLocalBox == nil) {
            // didSet이 목록을 불러온다.
            selectedFolderID = folders.first { $0.kind == "inbox" }?.id ?? folders.first?.id
        } else {
            await loadMessages()
        }
        updateMenu()
    }

    /// 받은 메일 가져오기: 선택한 폴더와 메일을 유지한 채 다시 불러온다.
    func refresh() async {
        guard isSignedIn else { return }
        await loadFolders()
        await loadMessages(keepSelection: true)
    }

    /// 계정마다 폴더를 불러온다 (사이드바는 계정별 구역). `folders`는 지금 계정의 것.
    func loadFolders() async {
        for account in accounts.accounts {
            // 처음에는 저장된 폴더를 먼저 보여 준다 (S-026).
            if accountFolders[account.id] == nil, let saved = account.service.cache?.folders() {
                accountFolders[account.id] = FolderOrder.tree(saved)
            }
            do {
                accountFolders[account.id] = FolderOrder.tree(try await router.folders(of: account))
            } catch {
                report(error)
            }
        }
        folders = accounts.active.flatMap { accountFolders[$0.id] } ?? []
        updateBadge()
        updateMenu()
    }

    /// 이 폴더·메일의 계정을 지금 계정으로 (보내기·답장·회의 응답이 그 계정으로 가게)
    func activateAccount(_ id: String?) {
        guard let id, id != accounts.activeID, accounts.accounts.contains(where: { $0.id == id }) else { return }
        accounts.activeID = id
        folders = accountFolders[id] ?? folders
    }

    /// 계정이 둘 이상이면 사이드바 맨 위에 "모든 받은 편지함"
    var showsAllInboxes: Bool { accounts.accounts.count > 1 }

    /// 계정마다 받은 편지함 폴더
    var inboxIDs: [(account: String, folder: String)] {
        accounts.accounts.compactMap { a in
            accountFolders[a.id]?.first { $0.kind == "inbox" }.map { (a.id, $0.id) }
        }
    }

    func loadMessages(keepSelection: Bool = false) async {
        guard let folderID = selectedFolderID else { return }
        // 나의 Mac에 (S-055): 서버가 아니라 이 Mac의 파일에서 읽는다.
        if let localID = LocalMailbox.id(fromSidebar: folderID) {
            messages = []
            selection = []
            localHits = []
            await localBoxes.open(localID)
            return
        }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        // 모든 폴더 검색이면 나의 Mac에 상자도 찾는다. 서버보다 먼저: 오프라인이어도 보인다.
        if !search.isEmpty && searchScope == .all {
            let hits = await localBoxes.searchAll(search)
            if folderID == selectedFolderID, search == searchText.trimmingCharacters(in: .whitespaces) { localHits = hits }
        } else {
            localHits = []
        }
        // 비어 있으면 저장된 목록을 먼저 보여 주고 서버 응답으로 바꾼다 (S-026).
        if messages.isEmpty, search.isEmpty, let saved = cachedService?.cache?.list(folderID: folderID) {
            messages = saved.messages
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page: MessagePage
            if !search.isEmpty && (searchScope == .all || VirtualMailbox.isVirtual(folderID)) {
                // 모든 폴더 검색 (S-033). 깃발 표시·VIP·스마트 메일상자는 서버 폴더가 아니라서 그 안의 검색도 전체 검색이다.
                page = try await service.searchAll(search)
            } else if let box = VirtualMailbox(id: folderID) {
                page = try await loadVirtual(box)
            } else {
                page = try await service.messages(folderID: folderID, search: search.isEmpty ? nil : search,
                                                  filter: listFilter.isActive ? listFilter : nil,
                                                  oldestFirst: listSort.serverOldestFirst)
            }
            // 기다리는 사이 폴더나 검색어가 바뀌었으면 버린다.
            guard folderID == selectedFolderID, search == searchText.trimmingCharacters(in: .whitespaces) else { return }
            // 서버 폴더가 아닌 상자·모든 폴더 검색은 서버 필터를 쓰지 않으므로 앱이 다 건다.
            let serverFiltered = page.serverFiltered && !VirtualMailbox.isVirtual(folderID) && search.isEmpty
            messages = arrange(page.messages, serverFiltered: serverFiltered)
            Task { await loadRelated(for: folderID, searching: !search.isEmpty) }
            addressBook.noteSeen(page.messages, me: auth.email)
            nextLink = page.nextLink
            if let pending = pendingOpenID, messages.contains(where: { $0.id == pending }) {
                pendingOpenID = nil
                selectedMessageID = pending
            } else if !(keepSelection && messages.contains { $0.id == selectedMessageID }) {
                selectedMessageID = nil
            }
        } catch {
            report(error)
        }
    }

    /// 대화별 정리용 관련 메일: 받은 편지함 등은 보낸 편지함의 최근 메일, 보낸 편지함은 받은 편지함의 최근 메일.
    /// 그래서 내 답장이 있는 대화는 어느 폴더에서나 같은 모양(수, 참여자)으로 보인다.
    func loadRelated(for folderID: String, searching: Bool) async {
        guard Self.organizeByConversation, !searching, !VirtualMailbox.isVirtual(folderID) else {
            relatedMessages = []
            return
        }
        let kind = folders.first { $0.id == folderID }?.kind ?? folderID
        guard !["drafts", "deleteditems", "junkemail", "outbox"].contains(kind) else {
            relatedMessages = []
            return
        }
        // 설정 > 보기 > "관련된 메시지 포함"을 끄면 다른 폴더의 메일은 세지 않는다 (대화 목록과 같은 규칙).
        guard Prefs.bool(Prefs.threadAllFolders, true) else {
            relatedMessages = []
            return
        }
        let other = kind == "sentitems" ? "inbox" : "sentitems"
        let list = (try? await service.messages(folderID: other, search: nil).messages) ?? []
        guard folderID == selectedFolderID else { return }
        relatedMessages = list
    }

    /// 목록 끝에 닿으면 다음 쪽을 더 불러온다.
    func loadMore() async {
        guard let link = nextLink, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.nextPage(link)
            guard link == nextLink else { return }
            let known = Set(messages.map(\.id))
            let more = arrange(page.messages, serverFiltered: page.serverFiltered).filter { !known.contains($0.id) }
            messages = listSort.apply(messages + more)
            nextLink = page.nextLink
        } catch {
            report(error)
        }
    }

    /// 보려는 메일이 기억에 있으면 그 자리에서 바로 바꿔 보인다 (loadDetail의 Task를 기다리지 않는다, AppModel+Prefetch).
    /// 없으면 아무것도 바꾸지 않는다: 새 본문이 올 때까지 지금 화면을 그대로 둔다.
    func showCachedDetail() {
        guard let id = displayedMessageID, let hit = detailCache.get(id) else { return }
        let m = withCurrentState(hit.message)
        detail = m
        detailAttachments = hit.attachments ?? []
        detailBody = MailContent.displayBody(m.body, attachments: hit.attachments ?? [])
    }

    func loadDetail() async {
        guard let id = displayedMessageID else {
            detail = nil; detailBody = nil; detailAttachments = []
            updateMenu()
            return
        }
        // 이 메일의 계정이 지금 계정이 된다: 답장·회의 응답이 그 계정으로 간다 (모든 받은 편지함, M23)
        activateAccount(router.accountID(forMessage: id))
        // 한 번 열었거나 미리 받은 메일: 서버를 기다리지 않고 바로 보인다.
        if let hit = detailCache.get(id) {
            let m = withCurrentState(hit.message)
            detail = m
            detailAttachments = hit.attachments ?? []
            detailBody = MailContent.displayBody(m.body, attachments: hit.attachments ?? [])
            updateMenu()
            if m.isUnread { Task { await markReadAfterOpening(id) } }
            prefetchNeighbors(of: id)
            if hit.attachments == nil, Self.needsAttachments(m) {
                if let attachments = try? await service.attachments(messageID: id) {
                    detailCache.setAttachments(id, attachments)
                    guard id == displayedMessageID else { return }
                    detailAttachments = attachments
                    detailBody = MailContent.displayBody(m.body, attachments: attachments)
                    updateMenu()
                }
            }
            return
        }
        do {
            // 목록 줄에 첨부가 있다고 나오면 첨부 목록을 본문과 같이(동시에) 요청한다.
            let rowHasAttachments = messages.first(where: { $0.id == id })?.hasAttachments == true
            let attachmentsTask: Task<[FileAttachment]?, Never>? = rowHasAttachments
                ? Task { try? await service.attachments(messageID: id) } : nil
            // 본문을 먼저 보이고(첨부를 기다리지 않는다), 첨부 목록과 인라인 그림은 뒤이어 채운다.
            let m = try await service.message(id: id)
            guard id == displayedMessageID else { attachmentsTask?.cancel(); return }
            detail = m
            detailAttachments = []
            detailBody = MailContent.displayBody(m.body, attachments: [])
            updateMenu()
            addressBook.noteSeen([m], me: auth.email)
            if m.isUnread { Task { await markReadAfterOpening(id) } }
            detailCache.put(id, DetailCache.Entry(message: m, attachments: Self.needsAttachments(m) ? nil : []))
            prefetchNeighbors(of: id)
            if Self.needsAttachments(m) {
                var attachments: [FileAttachment]? = await attachmentsTask?.value
                if attachments == nil { attachments = try await service.attachments(messageID: id) }
                let list = attachments ?? []
                detailCache.setAttachments(id, list)
                guard id == displayedMessageID else { return }
                detailAttachments = list
                detailBody = MailContent.displayBody(m.body, attachments: list)
                updateMenu()
            }
        } catch let error as GraphError where error.status == 404 {
            // 목록에는 있지만 서버에는 없다: 다른 기기·Outlook·규칙이 옮겼거나(옮기면 id가 바뀐다) 지웠다.
            forgetMissing(id)
        } catch {
            report(error)
        }
    }

    /// 서버에서 사라진 메일을 목록과 기억에서 빼고, 목록을 조용히 새로 고친다 (오류 창을 띄우지 않는다).
    func forgetMissing(_ id: String) {
        detailCache.remove(id)
        threadCache = [:]
        messages.removeAll { $0.id == id }
        selection.remove(id)
        if displayedMessageID == id {
            shownMessageID = nil
            if selectedMessageID == id { selectedMessageID = nil }
            detail = nil; detailBody = nil; detailAttachments = []
            missingMessageNotice = true
        }
        updateMenu()
        refreshAfterNotFound()
    }

    /// 404가 이어져도 새로 고침은 10초에 한 번만 (새로 고침이 또 404를 내도 되풀이하지 않게).
    func refreshAfterNotFound() {
        if let last = lastNotFoundRefresh, Date().timeIntervalSince(last) < 10 { return }
        lastNotFoundRefresh = Date()
        Task { await loadMessages(keepSelection: true) }
    }

    /// 필터의 앱 쪽 부분을 걸고 정렬한다 (S-041, S-042).
    func arrange(_ list: [MailMessage], serverFiltered: Bool) -> [MailMessage] {
        let me = auth.email.map { MailAddress(name: auth.displayName, address: $0) }
        let kept = listFilter.isActive ? list.filter { listFilter.matches($0, me: me, serverFiltered: serverFiltered) } : list
        return listSort.apply(kept)
    }

    // MARK: 바꾸기

    func setRead(id: String, _ read: Bool) async {
        do {
            try await service.setRead(id: id, read: read)
            if let i = messages.firstIndex(where: { $0.id == id }), messages[i].isRead != read {
                messages[i].isRead = read
                if let f = folders.firstIndex(where: { $0.id == selectedFolderID }) {
                    folders[f].unreadItemCount = max(0, (folders[f].unreadItemCount ?? 0) + (read ? -1 : 1))
                }
            }
            if detail?.id == id { detail?.isRead = read }
            if let t = thread.firstIndex(where: { $0.id == id }) { thread[t].isRead = read }
            for (key, cached) in threadCache {
                if let t = cached.list.firstIndex(where: { $0.id == id }) { threadCache[key]?.list[t].isRead = read }
            }
            updateBadge()
            updateMenu()
        } catch {
            report(error)
        }
    }

    /// 목록에서 위아래 메일로 옮긴다. 끝에서는 그대로 있는다. 옮겼으면 true.
    @discardableResult
    func selectAdjacent(_ offset: Int) -> Bool {
        let order = navigationOrder
        guard !order.isEmpty else { return false }
        let current = order.firstIndex { $0 == selectedMessageID }
        let target = current.map { $0 + offset } ?? (offset > 0 ? 0 : order.count - 1)
        guard order.indices.contains(target) else { return false }
        selectedMessageID = order[target]
        return true
    }

    /// Space: 본문을 한 쪽 내리고, 끝이었으면 다음 메일. ⇧Space: 한 쪽 올리고, 처음이었으면 이전 메일 (맥 Mail과 같다).
    func pageOrAdvance(down: Bool) async {
        guard detail != nil else {
            selectAdjacent(down ? 1 : -1)
            return
        }
        if await pageScroller.page(down: down) {
            selectAdjacent(down ? 1 : -1)
        }
    }

    /// 고른 메일을 모두 읽음(하나라도 안 읽었으면) 또는 모두 안 읽음으로 (S-027).
    func toggleReadSelected() async {
        let targets = messages.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let makeRead = targets.contains(where: \.isUnread)
        for m in targets where m.isUnread == makeRead { await setRead(id: m.id, makeRead) }
    }

    /// 보관도 지우기처럼 ⌘Z로 되돌린다 (창의 되돌리기 관리자를 넘긴다).
    func archiveSelected(undoManager: UndoManager? = nil) async {
        await moveSelected(to: "archive", undoManager: undoManager, undoName: L("보관"))
    }

    func deleteSelected(undoManager: UndoManager?) async {
        await moveSelected(to: "deleteditems", undoManager: undoManager, undoName: L("지우기"))
    }

    /// 고른 메일(여러 통, 대화별이면 대화 전체)을 옮긴다 (S-027).
    func moveSelected(to destination: String, undoManager: UndoManager?, undoName: String) async {
        await move(selectedIDs, to: destination, undoManager: undoManager, undoName: undoName)
    }

    /// 메일을 옮기고 다음 줄을 고른다. ⌘Z는 메일마다 원래 폴더로 되돌린다 (S-028).
    func move(_ ids: [String], to destination: String, undoManager: UndoManager?, undoName: String) async {
        let targets = messages.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let order = navigationOrder
        let position = order.firstIndex { ids.contains($0) } ?? 0
        var moves: [UndoMove] = []
        do {
            for m in targets {
                // 깃발 모아 보기처럼 여러 폴더가 섞인 목록에서도 원래 폴더로 돌아가게 메일의 폴더를 기억한다.
                let from = m.parentFolderId ?? selectedFolderID ?? "inbox"
                let newID = try await service.move(id: m.id, to: destination)
                threadCache = [:]   // 대화가 바뀌었다 (AppModel+Prefetch)
                moves.append(UndoMove(messageID: newID, folderID: from))
            }
        } catch {
            // 사람이 누른 동작이라 오프라인이어도 알린다.
            report(error, quietIfOffline: false)
        }
        guard !moves.isEmpty else { return }
        let movedOld = Set(targets.prefix(moves.count).map(\.id))
        messages.removeAll { movedOld.contains($0.id) }
        selection = []
        let remaining = navigationOrder
        // 설정 > 보기 > "메시지를 폐기하거나 아카이브한 후 자동으로 다음 메시지를 봅니다"
        let selectNext = Prefs.bool(Prefs.selectNextAfterMove, true)
        selectedMessageID = remaining.isEmpty || !selectNext ? nil : remaining[min(position, remaining.count - 1)]
        let undoMoves = moves
        undoManager?.registerUndo(withTarget: self) { target in
            // 되돌리기는 메인 스레드에서 불린다.
            MainActor.assumeIsolated {
                _ = Task { await target.restore(undoMoves) }
            }
        }
        undoManager?.setActionName(undoName)
        if let f = folders.first(where: { $0.id == destination || $0.wellKnownName == destination }),
           !["archive", "deleteditems", "junkemail"].contains(f.kind ?? "") {
            lastMoveTarget = MoveTarget(id: f.id, title: f.displayName)
        }
        await loadFolders()
    }

    struct UndoMove: Sendable {
        var messageID: String
        var folderID: String
    }

    func restore(_ moves: [UndoMove]) async {
        do {
            for m in moves { _ = try await service.move(id: m.messageID, to: m.folderID) }
            threadCache = [:]   // 대화가 바뀌었다 (AppModel+Prefetch)
            await refresh()
        } catch {
            report(error, quietIfOffline: false)
        }
    }

    /// 대화 안의 다른 메일을 펼친다 (S-025). 목록 선택은 그대로 두고 본문만 바꾼다.
    func showInThread(_ id: String) {
        guard id != displayedMessageID else { return }
        shownMessageID = id == selectedMessageID ? nil : id
        allowRemoteFor = nil
        showCachedDetail()
        Task { await loadDetail() }
    }

    /// 회의 초대에 답한다 (S-038). Exchange는 응답을 비동기로 처리하므로, 보낸 뒤 일정을 다시 읽어
    /// 서버가 실제로 기록한 상태를 막대에 보인다. 몇 초 안에 반영되지 않으면 서버 상태와 함께 알린다.
    func respondToMeeting(_ response: MeetingResponse) async {
        guard let eventID = detail?.event?.id, let original = detail?.event else { return }
        let subject = detail?.subject
        do {
            try await service.respond(toEvent: eventID, with: response)
        } catch {
            report(error, quietIfOffline: false)
            return
        }
        var serverValue: String?
        for wait in [1.0, 2.0, 3.0] {
            try? await Task.sleep(for: .seconds(wait))
            do {
                let fresh = try await service.event(id: eventID)
                serverValue = fresh.responseStatus?.response
                if detail?.event?.id == eventID { detail?.event = fresh }
                if serverValue == response.graphValue { break }
            } catch {
                errorMessage = L("회의 응답은 보냈지만 일정을 다시 찾을 수 없습니다. 주최자가 일정을 바꿨거나 취소했을 수 있습니다. ")
                    + L("Outlook 웹에서 확인해 주세요.\n(\(error.localizedDescription))")
                return
            }
        }
        // 맥 캘린더에도 넣거나(수락·미정) 앱이 넣은 것을 지운다(거절) (S-056)
        let latest = detail?.event?.id == eventID ? (detail?.event ?? original) : original
        await syncMacCalendar(after: response, event: latest, subject: subject)
        // 메일에 딸린 일정의 상태만으로는 부족하다: 실제 일정(캘린더 보기)에 그 회의가 들어갔는지 확인한다.
        guard response != .decline, let check = try? await service.meetingCheck(eventID: eventID) else { return }
        meetingCheck = check
        if !check.otherEventIDs.isEmpty {
            // 캘린더에 있는 같은 회의가 다른 일정이면 그 일정에도 같은 응답을 보낸다.
            for other in check.otherEventIDs { try? await service.respond(toEvent: other, with: response) }
            try? await Task.sleep(for: .seconds(2))
            if let again = try? await service.meetingCheck(eventID: eventID) { meetingCheck = again }
        }
        let final = meetingCheck ?? check
        if !final.foundInCalendarView || final.isCancelled || final.calendarViewResponse != response.graphValue {
            noticeMessage = L("회의 응답(\(response.label))을 보냈습니다. 확인 결과: \(final.summary). ")
                + L("아래 '일정에서 보기'로 Outlook 웹 일정을 열어 확인해 주세요.")
        }
    }

    /// 설정 > 보기 > '읽음으로 표시' 동작: 바로(기본), 5초 뒤(그때도 보고 있으면), 하지 않음
    func markReadAfterOpening(_ id: String) async {
        switch Prefs.string(Prefs.markRead, "now") {
        case "never":
            return
        case "delay":
            // 기다리는 동안 본문 불러오기(대화 등)를 막지 않게 따로 돈다.
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard displayedMessageID == id else { return }
                await setRead(id: id, true)
            }
        default:
            await setRead(id: id, true)
        }
    }

    /// 내용이 있는 첨부. Graph 첨부 목록은 큰 파일과 첨부된 메일(itemAttachment)의 내용을 빼고 주므로,
    /// 열기·저장·전달할 때 `$value`로 받아 채운다. 받은 내용은 본문 첨부 목록에도 넣어 다시 받지 않는다.
    func loadedAttachment(_ a: FileAttachment, messageID: String? = nil) async -> FileAttachment? {
        if a.data != nil { return a }
        if (a.odataType ?? "").hasSuffix("referenceAttachment") {
            errorMessage = L("\(a.name)은(는) OneDrive·SharePoint 링크로 붙인 파일입니다. Outlook 웹에서 열어 주세요.")
            return nil
        }
        guard let mid = messageID ?? detail?.id else { return nil }
        do {
            let data = try await service.attachmentContent(messageID: mid, attachmentID: a.id)
            // 첨부된 메일은 .eml로 저장해야 메일 앱이 연다.
            let isItem = (a.odataType ?? "").hasSuffix("itemAttachment")
            let name = isItem && (a.name as NSString).pathExtension.lowercased() != "eml" ? a.name + ".eml" : a.name
            let full = FileAttachment(id: a.id, name: name, contentType: isItem ? "message/rfc822" : a.contentType,
                                      size: a.size ?? data.count, isInline: a.isInline, contentId: a.contentId,
                                      contentBytes: data.base64EncodedString(), odataType: a.odataType)
            if let i = detailAttachments.firstIndex(where: { $0.id == a.id }) { detailAttachments[i] = full }
            return full
        } catch {
            report(error, quietIfOffline: false)
            if errorMessage == nil { errorMessage = L("첨부를 받지 못했습니다: \(error.localizedDescription)") }
            return nil
        }
    }

    /// 본문에 보이는 메일이 `id`이면 고친다 (다른 파일의 확장이 `detail`을 바꿀 때).
    func patchDetail(_ id: String, _ change: (inout MailMessage) -> Void) {
        guard var m = detail, m.id == id else { return }
        change(&m)
        detail = m
    }

    func allowRemoteContentForSelection() {
        allowRemoteFor = detail?.id
        updateMenu()
    }

    // MARK: helpers

    /// 오류를 알린다. 오프라인이면 막대가 이미 말해 주므로, 자동으로 일어난 일은 조용히 넘긴다 (S-026).
    func report(_ error: Error, quietIfOffline: Bool = true) {
        if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
        if OfflineError.isOffline(error) {
            isOffline = true
            if quietIfOffline { return }
            errorMessage = (error as? OfflineError)?.localizedDescription ?? OfflineError.unavailable(L("이 작업을 할")).localizedDescription
            return
        }
        // 없는 메일(404): 다른 곳에서 옮겨졌거나 지워졌다. 오류 창 대신 목록을 새로 고쳐 실제 상태를 보인다.
        if let g = error as? GraphError, g.status == 404 {
            refreshAfterNotFound()
            return
        }
        errorMessage = error.localizedDescription
    }

    func updateMenu() {
        MenuState.shared.update(MenuSnapshot(
            signedIn: isSignedIn,
            hasMessage: detail != nil && selectedMessageID != nil,
            hasSelection: !selectedIDs.isEmpty,
            isUnread: messages.filter { selectedIDs.contains($0.id) }.contains(where: \.isUnread),
            isFlagged: !messages.filter { selectedIDs.contains($0.id) }.contains { !$0.isFlagged },
            inJunk: selectedFolder?.kind == "junkemail",
            hasAttachments: !listedAttachments.isEmpty,
            canPrint: detail != nil && multipleSelectionCount == 0,
            sortKey: listSort.key,
            sortDescending: listSort.descending,
            filter: listFilter,
            isDraft: isDraftSelected,
            hasRemoteContent: detailHasRemoteContent && detailRemote != .allowed,
            senderIsVIP: detail.flatMap { mailboxes.vip(for: $0) } != nil,
            lastMoveTitle: lastMoveTarget?.title,
            isMuted: selectionIsMuted,
            importance: detail?.importance,
            inServerFolder: isSignedIn && selectedFolderID != nil && !VirtualMailbox.isVirtual(selectedFolderID)
                && selectedLocalBox == nil,
            folderEditable: selectedEditableFolder != nil || selectedLocalBox != nil,
            smartSelected: { if case .smart = selectedVirtual { return true } else { return false } }(),
            moveTargets: moveTargets,
            exporting: archiveExporting,
            isMeeting: detail?.event != nil,
            localSelected: selectedLocalBox != nil))
    }
}

/// make()에서 계정 서비스를 만들 때 아직 없는 모델을 가리키는 칸 (오프라인 막대)
final class ModelBox {
    weak var model: AppModel?
}
