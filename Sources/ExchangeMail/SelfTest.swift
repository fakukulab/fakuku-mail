import AppKit
import ExchangeMailKit
import Foundation

/// Self-test for agents: runs the app's real functions on the demo mailbox and a /tmp store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/ExchangeMail-self ~/Applications/FAKUKU\ Mail.app/Contents/MacOS/ExchangeMail --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isDemo, let demo = model.demoService else {
            print("SELFTEST refused: set APP_STORE to a folder in /tmp")
            finish(code: 1)
            return
        }
        /// 선택을 바꾸면 didSet이 본문을 불러온다. 직접 부르지 않고 끝나기를 기다린다 (데모 서비스는 바로 답한다).
        @MainActor func open(_ id: String) async {
            model.selectedMessageID = id
            try? await Task.sleep(for: .seconds(0.4))
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await model.reloadAll()
            try? await Task.sleep(for: .seconds(0.3))

            // S-002
            check("S-002 시작하면 받은 편지함이 선택된다", model.selectedFolderID == "inbox")
            check("S-002 폴더는 잘 알려진 순서다", model.folders.prefix(3).map(\.id) == ["inbox", "drafts", "sentitems"])

            // S-003, S-004
            check("S-003 받은 편지함에 메일이 있다", !model.messages.isEmpty)
            let unreadBefore = model.selectedFolder?.unreadItemCount ?? 0
            await open("m1")
            check("S-004 메일을 열면 본문이 보인다", model.detail?.id == "m1" && model.detailBody != nil)
            check("S-004 cid 그림이 data URI로 바뀐다",
                  model.detailBody?.content.contains("data:image/svg+xml;base64,") == true
                      && model.detailBody?.content.contains("cid:") == false)
            check("S-004 안 읽은 메일을 열면 읽음이 된다",
                  model.messages.first { $0.id == "m1" }?.isRead == true
                      && (model.selectedFolder?.unreadItemCount ?? 0) == unreadBefore - 1)
            check("S-005 인라인 그림은 첨부 목록에 없다",
                  model.listedAttachments.map(\.name) == ["2024년 3분기 장비 견적서.pdf"])

            // S-016
            await open("m3")
            check("S-016 원격 이미지가 있으면 차단 막대가 뜬다", model.detailHasRemoteContent && !model.remoteContentAllowed)
            model.allowRemoteContentForSelection()
            check("S-016 불러오기를 누르면 허용된다", model.remoteContentAllowed)
            await open("m2")
            check("S-016 다른 메일로 옮기면 다시 차단된다", !model.remoteContentAllowed)

            // S-047 메일 활동 보호 (테스트 저장소라 설정은 저장하지 않는다)
            await open("m3")
            model.protectMailActivity = true
            check("S-047 메일 활동 보호가 켜져 있으면 원격 그림을 앱이 대신 받는다", model.detailRemote == .proxied)
            let shielded = model.protectedPage(id: "m3", body: model.detailBody, remote: .proxied)
            check("S-047 추적 픽셀은 빼고 나머지 그림은 대신 받는 주소로",
                  shielded.blockedTrackers == 1 && shielded.html.contains("\(TrackingProtection.scheme)://image?u=")
                      && !shielded.html.contains("wf/open") && !shielded.html.contains("src=\"https://news.example.com/banner.png"))
            check("S-047 대신 받는 주소만 허용하는 보안 정책",
                  shielded.html.contains("img-src data: \(TrackingProtection.scheme):"))
            model.protectMailActivity = false
            model.blockAllRemote = true
            check("S-047 보호를 끄고 모든 원격 콘텐츠 차단을 켜면 막는다", model.detailRemote == .blocked)
            model.blockAllRemote = false
            check("S-047 둘 다 끄면 원래 서버에서 불러온다", model.detailRemote == .allowed)
            model.protectMailActivity = true
            model.blockAllRemote = true
            var junkMail = MailMessage(id: "junk-test", subject: "x", from: nil, receivedDateTime: Date())
            junkMail.parentFolderId = "junkemail"
            check("S-047 정크 메일의 원격 그림은 보호를 켜도 막는다", model.remoteMode(for: junkMail, allowed: false) == .blocked)
            check("S-047 불러오기를 누른 메일은 그대로 불러온다", model.remoteMode(for: junkMail, allowed: true) == .allowed)

            // S-048 맥 Mail 같은 설정 탭
            check("S-048 설정 탭이 맥 Mail 순서로 나뉜다",
                  SettingsTab.allCases.map(\.title) == ["일반", "계정", "정크 메일", "보기", "작성", "서명", "규칙", "자동 응답", "알림"])

            // S-013
            // 열면 읽음이 되므로, 한 번 바꾸면 읽지 않음, 다시 바꾸면 읽음.
            let unreadOpen = model.selectedFolder?.unreadItemCount ?? 0
            await model.toggleReadSelected()
            check("S-013 읽지 않음으로 바꿀 수 있다", model.selectedMessage?.isUnread == true
                  && (model.selectedFolder?.unreadItemCount ?? 0) == unreadOpen + 1)
            await model.toggleReadSelected()
            check("S-013 다시 바꾸면 읽음", model.selectedMessage?.isRead == true
                  && (model.selectedFolder?.unreadItemCount ?? 0) == unreadOpen)

            // S-041 필터, S-042 정렬 (받은 편지함이 처음 상태일 때)
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.4))
            let unfilteredCount = model.messages.count
            await model.setRead(id: "m2", false)   // 앞 테스트가 모두 읽음으로 바꿨다
            model.listFilter.unread = true
            await model.loadMessages(keepSelection: true)
            check("S-041 읽지 않음 필터는 안 읽은 메일만",
                  model.messages.map(\.id).contains("m2") && model.messages.allSatisfy(\.isUnread))
            await model.setRead(id: "m2", true)
            model.listFilter = MailFilter()
            model.listFilter.highImportance = true
            await model.loadMessages(keepSelection: true)
            check("S-041 높은 우선순위 필터", model.messages.map(\.id) == ["m2"])
            model.listFilter = MailFilter()
            model.listFilter.category = "빨강 범주"
            await model.loadMessages(keepSelection: true)
            check("S-041 범주 필터", model.messages.map(\.id) == ["m2"] && model.categories.contains("빨강 범주"))
            model.listFilter = MailFilter()
            await model.loadMessages(keepSelection: true)
            check("S-041 모든 필터 해제하면 원래 목록", model.messages.count == unfilteredCount)

            model.listSort = MailSort(key: .sender, descending: false)
            let senders = model.messages.map { $0.from?.emailAddress.display ?? "" }
            check("S-042 보낸 사람 오름차순",
                  zip(senders, senders.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) != .orderedDescending })
            model.listSort = MailSort(key: .date, descending: false)
            await model.loadMessages(keepSelection: true)
            let dates = model.messages.compactMap(\.receivedDateTime)
            check("S-042 오래된 항목 우선", dates == dates.sorted())
            model.listSort = MailSort()
            await model.loadMessages(keepSelection: true)

            // S-032: 첨부 미리보기 파일
            await open("m1")
            if let pdf = model.listedAttachments.first {
                let url = model.previewFile(for: pdf)
                let written = url.flatMap { try? Data(contentsOf: $0) }
                check("S-032 첨부를 NFC 이름의 임시 파일로 써서 훑어본다",
                      url?.lastPathComponent == "2024년 3분기 장비 견적서.pdf" && written == pdf.data)
                model.preview(pdf)
                check("S-032 훑어보기를 누르면 Quick Look 주소가 정해진다", model.previewURL == url)
                model.previewURL = nil
                model.preview(FileAttachment(id: "x", name: "없음.pdf", contentType: nil, size: 10, isInline: false, contentBytes: nil))
                check("S-032 내용이 없는 첨부는 열지 않고 이유를 알린다", model.previewURL == nil && model.errorMessage != nil)
                model.errorMessage = nil
            }

            // S-033: 모든 폴더 검색
            model.searchScope = .all
            model.searchText = "견적"
            await model.loadMessages()
            let everywhere = model.messages.map(\.id)
            check("S-033 모든 폴더 검색은 다른 폴더의 메일도 찾는다", everywhere.contains("s2") && everywhere.contains("m1"))
            check("S-033 다른 폴더의 결과에는 폴더 꼬리표가 붙는다",
                  model.messages.first { $0.id == "s2" }.flatMap { model.folderTag(for: $0) } == "보낸 편지함")
            model.searchScope = .folder
            await model.loadMessages()
            check("S-033 이 폴더 검색은 이 폴더만", !model.messages.contains { $0.id == "s2" })
            model.searchText = ""
            await model.loadMessages()

            // S-025: 대화별로 묶어 보기 (설정을 잠깐 켜고 끝에서 되돌린다)
            let defaults = UserDefaults.standard
            let savedThreaded = defaults.object(forKey: "list.threaded")
            defaults.set(true, forKey: "list.threaded")
            let quote = model.conversations.first { $0.id == "conv-quote" }
            check("S-025 견적 대화는 목록에서 한 줄(2통)이다", quote?.count == 2 && quote?.latest.id == "m1")
            await model.setRead(id: "m7", false)
            await open("m2")
            await open("m1")
            check("S-025 대화를 열면 보낸 메일까지 3통이 오래된 순으로", model.thread.map(\.id) == ["s2", "m7", "m1"])
            check("S-025 다른 폴더의 메일에는 폴더 꼬리표", model.thread.first.flatMap { model.folderTag(for: $0) } == "보낸 편지함")
            check("S-025 대화를 열면 이 폴더의 그 대화가 모두 읽음", model.messages.first { $0.id == "m7" }?.isRead == true)
            model.showInThread("m7")
            try? await Task.sleep(for: .seconds(0.4))
            check("S-025 대화 안의 메일을 누르면 그 메일이 열린다", model.detail?.id == "m7" && model.selectedMessageID == "m1")
            check("S-025 답장은 펼친 메일에 대한 답장이다", model.draft(.reply)?.subject == "RE: [견적] 3분기 장비 견적 요청")
            model.showInThread("m1")
            try? await Task.sleep(for: .seconds(0.4))
            defaults.set(false, forKey: "list.threaded")
            check("S-025 대화별로 정리를 끄면 한 통씩 오간다", model.navigationOrder.contains("m7"))
            defaults.set(true, forKey: "list.threaded")
            check("S-025 대화별이면 대화 안 예전 메일로는 가지 않는다", !model.navigationOrder.contains("m7"))

            // S-007
            await open("m1")
            let reply = model.draft(.replyAll)
            check("S-007 전체 답장 제목", reply?.subject == "RE: [견적] 3분기 장비 견적서 송부드립니다")
            check("S-007 전체 답장 받는 사람과 참조", reply?.to.contains("minji.kim@fabrikam.com") == true
                  && reply?.cc.contains("seojun.park@fabrikam.com") == true
                  && reply?.cc.contains(DemoMailService.myAddress) == false)
            check("S-007 답장은 스레드 헤더를 갖는다", reply?.inReplyTo == "<m1@fabrikam.com>")
            check("S-007 인용문의 그림은 data URI다", reply?.quoteHTML.contains("data:image/svg+xml") == true)
            let forward = model.draft(.forward)
            check("S-007 전달은 원본 첨부를 가져온다", forward?.forwardAttachmentsFrom == "m1")

            // S-006, S-008, S-010: 작성 창이 쓰는 그대로 MIME을 만들고 보낸다
            let signature = model.signatures.defaultSignature(kind: .reply, account: model.auth.email)
            check("S-010 답장 기본 서명이 있다", signature?.name == "간단 서명")
            if let reply {
                let photo = "<img src=\"data:image/png;base64,\(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())\" alt=\"현장사진.png\">"
                let full = model.signatures.signatures.first { $0.name == "회사 서명" }
                let body = "<div>안녕하세요\(photo)</div>" + SignatureComposer.block(for: full) + reply.quoteHTML
                let nfdFile = FileManager.default.temporaryDirectory
                    .appending(path: "견적서_최종.pdf".decomposedStringWithCanonicalMapping)
                try? Data("pdf".utf8).write(to: nfdFile)
                let input = ComposeSender.Input(from: MailAddress(name: "데모 사용자", address: DemoMailService.myAddress),
                                                to: reply.to, cc: reply.cc, bcc: "", subject: reply.subject,
                                                bodyHTML: body, files: [nfdFile], extraAttachments: [],
                                                draft: reply, fixEnabled: true)
                do {
                    let mime = try ComposeSender.build(input, options: FixOptions())
                    let text = String(decoding: mime, as: UTF8.self)
                    check("S-006 본문 그림은 일반 첨부로 나간다", text.contains("filename*=UTF-8''%ED%98%84%EC%9E%A5%EC%82%AC%EC%A7%84.png"))
                    check("S-006 서명 그림은 인라인으로 남는다", text.contains("multipart/related") && text.contains("Content-ID: <"))
                    check("S-006 NFD 파일명이 NFC로 나간다",
                          text.contains(FilenameEncoder.rfc2231Parameter(key: "filename", filename: "견적서_최종.pdf")))
                    check("S-007 답장 MIME에 In-Reply-To가 있다", text.contains("In-Reply-To: <m1@fabrikam.com>"))
                    let sentBefore = demo.sent.count
                    try await model.service.sendMIME(mime)
                    check("S-006 보내면 서비스에 MIME이 전달된다", demo.sent.count == sentBefore + 1)

                    let off = try ComposeSender.build(ComposeSender.Input(
                        from: input.from, to: input.to, cc: "", bcc: "", subject: "x", bodyHTML: "<div>\(photo)</div>",
                        files: [], extraAttachments: [], draft: ComposeDraft(), fixEnabled: false), options: FixOptions())
                    let offText = String(decoding: off, as: UTF8.self)
                    check("S-008 보정을 끄면 본문 그림은 인라인", offText.contains("multipart/related") && !offText.contains("Content-Disposition: attachment"))
                } catch {
                    check("S-006 MIME 만들기", false, error.localizedDescription)
                }
                do {
                    _ = try ComposeSender.build(ComposeSender.Input(
                        from: input.from, to: "잘못된 주소", cc: "", bcc: "", subject: "x", bodyHTML: "x",
                        files: [], extraAttachments: [], draft: ComposeDraft(), fixEnabled: true), options: FixOptions())
                    check("S-006 잘못된 주소는 보내기 전에 막는다", false)
                } catch {
                    check("S-006 잘못된 주소는 보내기 전에 막는다",
                          (error as? ComposeSender.Problem) == .invalidAddresses(["잘못된 주소"]))
                }
                try? FileManager.default.removeItem(at: nfdFile)
            }

            // S-019: 위아래 메일로 옮기기 (Space가 본문 끝에서 쓰는 규칙). 대화별이면 대화 단위로 (S-025).
            let order = model.navigationOrder
            if order.count >= 2 {
                await open(order[0])
                check("S-019 다음 메일로 옮긴다", model.selectAdjacent(1) && model.selectedMessageID == order[1])
                check("S-019 이전 메일로 돌아온다", model.selectAdjacent(-1) && model.selectedMessageID == order[0])
                check("S-019 맨 위에서 위로는 그대로", !model.selectAdjacent(-1) && model.selectedMessageID == order[0])
                try? await Task.sleep(for: .seconds(0.4))
            }

            // S-018: 읽은 메일의 주소로 자동완성
            let found = model.addressBook.suggestions(for: "민지")
            check("S-018 읽은 메일의 주소가 자동완성에 나온다", found.first?.address == "minji.kim@fabrikam.com")
            check("S-018 내 주소는 자동완성에 없다",
                  model.addressBook.suggestions(for: "me@").allSatisfy { $0.address != DemoMailService.myAddress })
            check("S-018 고르면 마지막 항목이 주소로 바뀐다",
                  AddressBook.complete("a@b.com, 민지", with: MailAddress(name: "김민지", address: "minji.kim@fabrikam.com"))
                      == "a@b.com, 김민지 <minji.kim@fabrikam.com>, ")

            // S-017: 끌어다 놓기와 파일 선택이 같이 쓰는 규칙 (실제 파일로)
            let dropDir = FileManager.default.temporaryDirectory.appending(path: "selftest-drop", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dropDir.appending(path: "폴더"), withIntermediateDirectories: true)
            let dropFile = dropDir.appending(path: "현장사진.jpg")
            try? Data([1]).write(to: dropFile)
            let merged = AttachmentList.merge([], adding: [dropFile, dropFile, dropDir.appending(path: "폴더")])
            check("S-017 같은 파일은 한 번만 첨부된다", merged.files == [dropFile])
            check("S-017 폴더는 건너뛰고 알린다", merged.skipped == ["폴더"])
            try? FileManager.default.removeItem(at: dropDir)

            // S-011, S-012
            await open("m2")
            let countBefore = model.messages.count
            await model.archiveSelected()
            check("S-011 보관하면 목록에서 사라진다", model.messages.count == countBefore - 1 && !model.messages.contains { $0.id == "m2" })
            check("S-011 다음 메일이 선택된다", model.selectedMessageID != nil)
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            await model.deleteSelected(undoManager: undo)
            undo.endUndoGrouping()
            check("S-012 지우면 목록에서 사라진다", model.messages.count == countBefore - 2)
            check("S-012 되돌리기가 등록된다", undo.canUndo)
            undo.undo()
            try? await Task.sleep(for: .seconds(0.8))
            check("S-012 ⌘Z로 지운 메일이 돌아온다", model.messages.count == countBefore - 1)

            // S-011: 보관도 ⌘Z로 되돌린다
            let archiveUndo = UndoManager()
            archiveUndo.groupsByEvent = false
            let beforeArchive = model.messages.count
            archiveUndo.beginUndoGrouping()
            await model.archiveSelected(undoManager: archiveUndo)
            archiveUndo.endUndoGrouping()
            check("S-011 보관하면 되돌리기가 등록된다", archiveUndo.canUndo && model.messages.count < beforeArchive)
            archiveUndo.undo()
            try? await Task.sleep(for: .seconds(0.8))
            check("S-011 ⌘Z로 보관한 메일이 돌아온다", model.messages.count == beforeArchive)

            // S-014
            let listCount = model.messages.count
            model.searchText = "견적"
            await model.loadMessages()
            check("S-014 검색은 맞는 메일만 보인다",
                  !model.messages.isEmpty && model.messages.allSatisfy { $0.title.contains("견적") })
            model.searchText = ""
            await model.loadMessages()
            check("S-014 검색어를 지우면 원래 목록", model.messages.count == listCount)

            // S-015
            if let keep = model.messages.first?.id {
                await open(keep)
                await model.refresh()
                check("S-015 새로고침해도 선택이 남는다", model.selectedMessageID == keep)
            }

            // S-009
            let store = model.signatures
            let added = store.add()
            check("S-009 서명을 추가하면 끝에 생긴다", store.signatures.last?.id == added.id)
            store.setRule(.forward, to: added.id)
            store.delete(id: added.id)
            check("S-009 지운 서명은 기본 규칙에서도 빠진다", store.ruleSelection(.forward) == nil)
            check("S-009 서명은 파일로 저장된다", store.fileExists)

            // S-021: 이 계정만의 기본 서명
            let me = model.auth.email
            let short = store.signatures.first { $0.name == "간단 서명" }
            if let short {
                store.setChoice(.signature(short.id), kind: .new, account: me)
                check("S-021 계정 규칙이 모든 계정 규칙보다 앞선다", store.defaultSignature(kind: .new, account: me)?.id == short.id)
                store.setChoice(.inherit, kind: .new, account: me)
                check("S-021 따르기를 고르면 모든 계정 규칙으로 돌아간다",
                      store.defaultSignature(kind: .new, account: me)?.name == "회사 서명")
                store.setChoice(.none, kind: .forward, account: me)
                check("S-021 계정에서 없음을 고르면 서명을 넣지 않는다", store.defaultSignature(kind: .forward, account: me) == nil)
                store.setChoice(.inherit, kind: .forward, account: me)
            }

            // S-022: 초안 저장, 이어서 쓰기, 보내면 정리, 버리기
            // 클로저 안의 async 지역 함수는 메인 액터를 물려받지 않는다. model은 메인 액터 것이므로 명시한다.
            @MainActor func draftCount() async -> Int {
                (try? await model.service.messages(folderID: "drafts", search: nil).messages.count) ?? -1
            }
            let draftsBefore = await draftCount()
            let c = ComposeModel(draft: ComposeDraft())
            await c.setUp(app: model, fixDefault: true)
            check("S-022 아무것도 안 쓴 창은 저장할 것이 없다", !c.hasUnsavedChanges)
            c.to = "잘못된 주소"
            c.subject = "초안 테스트"
            check("S-022 고치면 저장할 것이 생긴다", c.hasUnsavedChanges)
            let firstSave = await c.saveDraft(app: model)
            let afterFirst = await draftCount()
            check("S-022 주소가 틀려도 초안으로 저장된다",
                  firstSave && c.savedDraftID != nil && afterFirst == draftsBefore + 1)
            c.subject = "초안 테스트 2"
            await c.saveDraft(app: model)
            let afterSecond = await draftCount()
            check("S-022 다시 저장하면 초안을 바꾸고 늘리지 않는다", afterSecond == draftsBefore + 1)
            check("S-022 저장한 뒤에는 저장할 것이 없다", !c.hasUnsavedChanges)

            model.selectedFolderID = "drafts"
            try? await Task.sleep(for: .seconds(0.5))
            if let savedID = c.savedDraftID {
                await open(savedID)
                let resumed = model.resumeDraft()
                check("S-022 초안을 이어서 쓰면 제목과 초안 id가 이어진다",
                      resumed?.subject == "초안 테스트 2" && resumed?.draftMessageID == savedID)
                if let resumed {
                    let r = ComposeModel(draft: resumed)
                    await r.setUp(app: model, fixDefault: true)
                    r.to = "client@x.com"
                    let sentOK = await r.send(app: model)
                    let afterSend = await draftCount()
                    check("S-022 이어 쓴 초안을 보내면 임시 보관함에서 지워진다", sentOK && afterSend == draftsBefore)
                }
            }
            let thrown = ComposeModel(draft: ComposeDraft())
            await thrown.setUp(app: model, fixDefault: true)
            thrown.subject = "버릴 메일"
            await thrown.saveDraft(app: model)
            await thrown.discard(app: model)
            let afterDiscard = await draftCount()
            check("S-022 삭제하면 저장된 초안도 지우고 다시 저장하지 않는다",
                  afterDiscard == draftsBefore && !thrown.hasUnsavedChanges)

            // S-023: 4MB가 넘는 메일 (5MB 첨부)
            let bigDir = FileManager.default.temporaryDirectory.appending(path: "selftest-big", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
            let bigFile = bigDir.appending(path: "현장 보고서.pdf".decomposedStringWithCanonicalMapping)
            try? Data(count: 5 * 1024 * 1024).write(to: bigFile)
            let draftsBeforeBig = await draftCount()
            let uploadsBefore = demo.uploaded.count
            let big = ComposeModel(draft: ComposeDraft())
            await big.setUp(app: model, fixDefault: true)
            big.to = "client@x.com"
            big.subject = "큰 첨부"
            big.addFiles([bigFile])
            check("S-023 큰 첨부를 넣으면 안내가 보인다", big.hasLargeAttachments)
            let bigSent = await big.send(app: model)
            let draftsAfterBig = await draftCount()
            check("S-023 5MB 첨부가 있는 메일이 보내진다", bigSent, big.error ?? "")
            check("S-023 큰 첨부는 NFC 이름으로 업로드된다",
                  demo.uploaded.count == uploadsBefore + 1 && demo.uploaded.last?.name == "현장 보고서.pdf"
                      && demo.uploaded.last?.size == 5 * 1024 * 1024)
            check("S-023 업로드한 초안은 보내지고 임시 보관함에 남지 않는다",
                  demo.sentDrafts.count == 1 && draftsAfterBig == draftsBeforeBig)
            check("S-023 보낸 뒤 진행 표시가 사라진다", big.uploadFraction == nil && big.uploadStatus == nil)

            let bigDraft = ComposeModel(draft: ComposeDraft())
            await bigDraft.setUp(app: model, fixDefault: true)
            bigDraft.subject = "큰 첨부 초안"
            bigDraft.addFiles([bigFile])
            let bigSaved = await bigDraft.saveDraft(app: model)
            check("S-023 큰 첨부가 있는 메일도 초안으로 저장된다",
                  bigSaved && bigDraft.savedDraftID != nil && demo.uploaded.count == uploadsBefore + 2)
            await bigDraft.discard(app: model)
            try? FileManager.default.removeItem(at: bigDir)

            // S-024: 새 메일 알림과 Dock 배지 (기록만 하는 알리미로)
            if let recorder = model.notifier as? RecordingNotifier {
                // 앱 실행 파일이 같아 사용자 설정을 공유한다. 바꾼 값은 끝에서 되돌린다.
                let defaults = UserDefaults.standard
                let savedNotify = defaults.object(forKey: "notify.newMail")
                let savedBadge = defaults.object(forKey: "notify.badge")
                defaults.set(true, forKey: "notify.newMail")
                defaults.set(true, forKey: "notify.badge")

                await model.prepareNotifications()
                model.selectedFolderID = "inbox"
                try? await Task.sleep(for: .seconds(0.5))
                await model.checkNewMail()
                check("S-024 처음 확인은 기준만 정하고 알리지 않는다", recorder.posted.isEmpty)
                demo.deliver(MailMessage(id: "n1", subject: "새 견적 요청",
                                         from: Recipient(name: "박서준", address: "seojun.park@fabrikam.com"),
                                         receivedDateTime: Date().addingTimeInterval(5),
                                         bodyPreview: "견적 부탁드립니다", isRead: false))
                await model.checkNewMail()
                check("S-024 새 메일이 오면 알림 1건 (보낸 사람, 제목)",
                      recorder.posted.count == 1 && recorder.posted.last?.messageID == "n1"
                          && recorder.posted.last?.title == "박서준" && recorder.posted.last?.subtitle == "새 견적 요청")
                await model.checkNewMail()
                check("S-024 다시 확인해도 알림이 늘지 않는다", recorder.posted.count == 1)
                let unread = model.folders.first { $0.kind == "inbox" }?.unreadItemCount
                check("S-024 Dock 배지는 받은 편지함의 읽지 않은 수",
                      recorder.badge != nil && recorder.badge == DockBadge.label(unread: unread))

                model.selectedFolderID = "sentitems"
                try? await Task.sleep(for: .seconds(0.5))
                await model.openFromNotification("n1")
                try? await Task.sleep(for: .seconds(0.6))
                check("S-024 알림을 누르면 받은 편지함의 그 메일이 열린다",
                      model.selectedFolderID == "inbox" && model.selectedMessageID == "n1")

                defaults.set(false, forKey: "notify.badge")
                model.updateBadge()
                check("S-024 배지를 끄면 사라진다", recorder.badge == nil)

                if let savedNotify { defaults.set(savedNotify, forKey: "notify.newMail") } else { defaults.removeObject(forKey: "notify.newMail") }
                if let savedBadge { defaults.set(savedBadge, forKey: "notify.badge") } else { defaults.removeObject(forKey: "notify.badge") }
            }

            // S-025: 대화 보관은 이 폴더의 그 대화를 모두 옮긴다 (받은 편지함을 바꾸므로 맨 끝에)
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.5))
            if model.messages.contains(where: { $0.id == "m1" }) {
                await open("m1")
                await model.archiveSelected()
                let archived = (try? await model.service.messages(folderID: "archive", search: nil).messages) ?? []
                check("S-025 대화를 보관하면 그 대화가 모두 옮겨진다",
                      !model.messages.contains { $0.conversationId == "conv-quote" }
                          && archived.filter { $0.conversationId == "conv-quote" }.count == 2)
            }
            if let savedThreaded { defaults.set(savedThreaded, forKey: "list.threaded") } else { defaults.removeObject(forKey: "list.threaded") }

            // S-026: 오프라인에서 저장된 메일 읽기 (저장 설정은 잠깐 켜고 되돌린다)
            let savedCacheSetting = UserDefaults.standard.object(forKey: "cache.enabled")
            UserDefaults.standard.set(true, forKey: "cache.enabled")
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.5))
            await model.refresh()
            let onlineIDs = model.messages.map(\.id)
            if let first = onlineIDs.first {
                await open(first)                 // 본문을 캐시에 남긴다
                let onlineBody = model.detailBody?.content
                demo.simulateOffline = true
                model.selectedMessageID = nil
                await model.refresh()
                check("S-026 오프라인이면 표시가 켜진다", model.isOffline)
                check("S-026 오프라인에서도 저장된 받은 편지함 목록이 보인다", model.messages.map(\.id) == onlineIDs)
                await open(first)
                check("S-026 오프라인에서도 열어 본 메일 본문이 보인다",
                      model.detail?.id == first && model.detailBody?.content == onlineBody)
                model.errorMessage = nil
                await model.archiveSelected()
                check("S-026 오프라인에서 보관은 하지 않고 이유를 알린다",
                      model.messages.contains { $0.id == first } && (model.errorMessage?.contains("오프라인") ?? false))
                model.errorMessage = nil
                let offlineCompose = ComposeModel(draft: ComposeDraft())
                await offlineCompose.setUp(app: model, fixDefault: true)
                offlineCompose.to = "client@x.com"
                let sentOffline = await offlineCompose.send(app: model)
                check("S-026 오프라인에서 보내기는 하지 않고 이유를 알린다",
                      !sentOffline && (offlineCompose.error?.contains("오프라인") ?? false))
                demo.simulateOffline = false
                await model.retryConnection()
                check("S-026 다시 연결되면 오프라인 표시가 꺼진다", !model.isOffline)
                let cacheSize = model.cachedService?.cache?.sizeBytes() ?? 0
                model.cachedService?.clearCache()
                check("S-026 저장된 메일을 지우면 캐시가 비워진다",
                      cacheSize > 0 && (model.cachedService?.cache?.sizeBytes() ?? -1) == 0)
            }
            if let savedCacheSetting {
                UserDefaults.standard.set(savedCacheSetting, forKey: "cache.enabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "cache.enabled")
            }

            // M9: 여러 통 선택, 이동, 깃발, 정크, 폴더
            defaults.set(false, forKey: "list.threaded")   // 한 통씩 보며 검사한다 (끝에서 되돌린다)
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.5))
            await model.refresh()
            if model.messages.count >= 3 {
                let two = Set(model.navigationOrder.prefix(2))
                model.selection = two
                try? await Task.sleep(for: .seconds(0.3))
                check("S-027 여러 통을 고르면 본문 대신 개수가 보인다",
                      model.multipleSelectionCount == 2 && model.selectedMessageID == nil && model.selectedIDs.count == 2)
                let before = model.messages.count
                let multiUndo = UndoManager()
                multiUndo.groupsByEvent = false
                multiUndo.beginUndoGrouping()
                await model.archiveSelected(undoManager: multiUndo)
                multiUndo.endUndoGrouping()
                check("S-027 여러 통을 보관하면 모두 옮겨진다", model.messages.count == before - 2 && two.isDisjoint(with: model.messages.map(\.id)))
                multiUndo.undo()
                try? await Task.sleep(for: .seconds(0.8))
                check("S-027 ⌘Z로 여러 통이 모두 돌아온다", model.messages.count == before)

                model.selection = Set(model.navigationOrder.prefix(2))
                await model.toggleReadSelected()
                let readStates = model.messages.filter { model.selection.contains($0.id) }.map(\.isUnread)
                check("S-027 여러 통 읽음 전환은 모두 같은 상태가 된다", Set(readStates).count == 1)

                // S-028 다른 폴더로 옮기기
                let moving = model.navigationOrder[0]
                model.selection = [moving]
                let moveUndo = UndoManager()
                moveUndo.groupsByEvent = false
                moveUndo.beginUndoGrouping()
                await model.dropped([moving], onto: "projects", undoManager: moveUndo)
                moveUndo.endUndoGrouping()
                let inProjects = (try? await model.service.messages(folderID: "projects", search: nil).messages.count) ?? 0
                check("S-028 끌어다 놓으면 그 폴더로 옮겨진다", !model.messages.contains { $0.id == moving } && inProjects == 1)
                moveUndo.undo()
                try? await Task.sleep(for: .seconds(0.8))
                let backInProjects = (try? await model.service.messages(folderID: "projects", search: nil).messages.count) ?? -1
                check("S-028 ⌘Z로 원래 폴더로 돌아온다", backInProjects == 0 && model.messages.count == before)

                // S-029 깃발
                let flagging = model.navigationOrder[0]
                model.selection = [flagging]
                await model.toggleFlagSelected()
                check("S-029 깃발을 달면 목록에 깃발이 보인다", model.messages.first { $0.id == flagging }?.isFlagged == true)
                model.selectedFolderID = FolderOrder.flaggedID
                try? await Task.sleep(for: .seconds(0.5))
                check("S-029 깃발 표시에 모인다", model.messages.map(\.id) == [flagging])
                model.selection = [flagging]
                await model.toggleFlagSelected()
                check("S-029 깃발을 떼면 깃발 표시에서 빠진다", model.messages.isEmpty)

                // S-030 정크
                model.selectedFolderID = "inbox"
                try? await Task.sleep(for: .seconds(0.5))
                let junking = model.navigationOrder[0]
                model.selection = [junking]
                await model.toggleJunkSelected(undoManager: nil)
                let junkCount = (try? await model.service.messages(folderID: "junkemail", search: nil).messages.count) ?? 0
                check("S-030 정크로 표시하면 정크 메일 폴더로 간다", !model.messages.contains { $0.id == junking } && junkCount == 1)
                model.selectedFolderID = "junkemail"
                try? await Task.sleep(for: .seconds(0.5))
                model.selection = Set(model.navigationOrder.prefix(1))
                await model.toggleJunkSelected(undoManager: nil)
                let junkAfter = (try? await model.service.messages(folderID: "junkemail", search: nil).messages.count) ?? -1
                check("S-030 정크 아님은 받은 편지함으로 돌려놓는다", junkAfter == 0)

                // S-031 폴더
                check("S-031 하위 폴더는 부모 아래에 들여 쓴다",
                      model.folders.firstIndex { $0.id == "projects-2024" } == (model.folders.firstIndex { $0.id == "projects" } ?? -9) + 1
                          && model.folders.first { $0.id == "projects-2024" }?.depth == 1)
                let made = await model.createFolder(named: "셀프 테스트", parentID: "projects")
                check("S-031 새 폴더를 만들면 사이드바에 생기고 골라진다",
                      made != nil && model.selectedFolderID == made?.id && model.folders.contains { $0.displayName == "셀프 테스트" })
                if let made {
                    let folder = model.folders.first { $0.id == made.id } ?? made
                    await model.renameFolder(folder, to: "셀프 테스트 2")
                    check("S-031 이름을 바꾸면 바뀐다", model.folders.first { $0.id == made.id }?.displayName == "셀프 테스트 2")
                    let renamed = model.folders.first { $0.id == made.id } ?? made
                    await model.deleteFolder(renamed)
                    check("S-031 지우면 사라진다", !model.folders.contains { $0.id == made.id })
                }
                let inbox = model.folders.first { $0.kind == "inbox" }
                check("S-031 기본 폴더는 이름 변경·지우기를 할 수 없다", inbox?.isEditable == false)
            }
            if let savedThreaded { defaults.set(savedThreaded, forKey: "list.threaded") } else { defaults.removeObject(forKey: "list.threaded") }

            // M11: 첨부 끌어 저장, 보내기 취소, 예약 보내기, 회의 초대
            let dragged = FileAttachment(id: "drag-1", name: "보고서.pdf".decomposedStringWithCanonicalMapping,
                                         contentType: "application/pdf", size: 3, isInline: false, contentBytes: "AQID")
            let provider = model.dragProvider(for: dragged)
            check("S-035 첨부를 끌면 NFC 이름의 파일을 넘긴다",
                  provider.suggestedName == "보고서.pdf" && !provider.registeredTypeIdentifiers.isEmpty)

            let undoable = ComposeModel(draft: ComposeDraft())
            await undoable.setUp(app: model, fixDefault: true)
            undoable.to = "client@x.com"
            undoable.subject = "보내기 취소 테스트"
            let sentBeforeUndo = demo.sent.count
            let pending = Task { await undoable.send(app: model, undoDelay: 3) }
            try? await Task.sleep(for: .seconds(1.2))
            check("S-036 보내기를 누르면 남은 초를 센다", (undoable.sendCountdown ?? 0) > 0)
            undoable.cancelSend()
            let undoneResult = await pending.value
            check("S-036 보내기 취소를 누르면 보내지 않고 창에 남는다",
                  !undoneResult && demo.sent.count == sentBeforeUndo && undoable.sendCountdown == nil && undoable.error == nil)
            let sentAfterWait = await undoable.send(app: model, undoDelay: 1)
            check("S-036 기다린 시간이 지나면 보낸다", sentAfterWait && demo.sent.count == sentBeforeUndo + 1)

            let later = ComposeModel(draft: ComposeDraft())
            await later.setUp(app: model, fixDefault: true)
            later.to = "client@x.com"
            later.subject = "예약 테스트"
            let tooSoon = await later.schedule(app: model, at: Date().addingTimeInterval(20))
            check("S-037 1분 안의 시각은 예약하지 않는다", !tooSoon && later.error != nil)
            later.error = nil
            let when = Date().addingTimeInterval(3_600)
            let scheduledBefore = demo.scheduled.count
            let scheduledOK = await later.schedule(app: model, at: when)
            check("S-037 예약하면 지연 발송 시각을 붙여 초안으로 보낸다",
                  scheduledOK && demo.scheduled.count == scheduledBefore + 1 && demo.scheduled.last?.at == when
                      && demo.sentDrafts.contains(demo.scheduled.last?.id ?? "-"))

            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.5))
            await model.refresh()
            if let invite = model.messages.first(where: \.isMeetingRequest) {
                await open(invite.id)
                check("S-038 회의 초대를 열면 일정이 보인다",
                      model.detail?.event?.location?.displayName == "3층 회의실" && !(model.detail?.event?.whenText().isEmpty ?? true))
                await model.respondToMeeting(.accept)
                check("S-038 수락하면 서버에서 다시 읽은 상태가 보인다",
                      model.detail?.event?.response == .accept && model.errorMessage == nil)
                await model.respondToMeeting(.tentativelyAccept)
                check("S-038 수락한 뒤 미정으로 바꿀 수 있다", model.detail?.event?.response == .tentativelyAccept)
            } else {
                check("S-038 데모 받은 편지함에 회의 초대가 있다", false)
            }

            // M12: 규칙, 자동 응답 (설정 화면이 쓰는 서비스 호출 그대로)
            let ruleDraft = RuleDraft(name: "견적 메일", field: .subject, text: "견적", action: .move(folderID: "projects"))
            if let made = try? await model.service.createRule(ruleDraft.rule(sequence: 1)) {
                let listed = (try? await model.service.rules()) ?? []
                check("S-039 규칙을 만들면 목록에 보인다", listed.contains { $0.id == made.id && $0.actions?.moveToFolder == "projects" })
                try? await model.service.setRule(id: made.id, enabled: false)
                let toggled = (try? await model.service.rules())?.first { $0.id == made.id }
                check("S-039 규칙을 끌 수 있다", toggled?.isEnabled == false)
                try? await model.service.deleteRule(id: made.id)
                let afterDelete = (try? await model.service.rules()) ?? []
                check("S-039 규칙을 지우면 사라진다", !afterDelete.contains { $0.id == made.id })
            } else {
                check("S-039 규칙을 만든다", false)
            }
            let away = AutomaticReplies.make(on: true, start: Date(), end: Date().addingTimeInterval(86_400), audience: "contactsOnly",
                                             internalText: "휴가 중입니다.", externalText: "I am away.")
            try? await model.service.setAutomaticReplies(away)
            let readBack = try? await model.service.automaticReplies()
            check("S-040 자동 응답을 저장하고 다시 읽는다",
                  readBack?.status == "scheduled" && AutomaticReplies.plain(readBack?.internalReplyMessage) == "휴가 중입니다."
                      && readBack?.externalAudience == "contactsOnly")

            // M14: 별도 창 (S-043). 창이 쓰는 리더와 모델 동작을 그대로 부른다.
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.5))
            if let first = model.messages.first(where: { !$0.isMeetingRequest }) {
                await open(first.id)
                check("S-043 받은 메일은 메시지 창으로 연다", model.openTarget() == .message(model.displayedMessageID ?? ""))
                let reader = MessageReader(messageID: first.id)
                await reader.load(using: model)
                check("S-043 창은 메일 한 통을 따로 읽는다", reader.message?.id == first.id && reader.body != nil && reader.failure == nil)
                check("S-043 창에서 답장하면 제목에 RE:가 붙는다",
                      reader.draft(.reply, model: model)?.subject.hasPrefix("RE:") == true)
                let wasFlagged = reader.message?.isFlagged ?? false
                await reader.toggleFlag(model: model)
                check("S-043 창에서 깃발을 달면 목록에도 보인다",
                      reader.message?.isFlagged == !wasFlagged
                          && model.messages.first { $0.id == first.id }?.isFlagged == !wasFlagged)
                await reader.toggleFlag(model: model)
            }
            let sentPage = try? await model.service.messages(folderID: "sentitems", search: nil)
            if let sent = sentPage?.messages.first {
                // 지금 보는 폴더(받은 편지함) 밖의 메일도 창에서 보관할 수 있다.
                let reader = MessageReader(messageID: sent.id)
                await reader.load(using: model)
                await reader.move(to: "archive", undoName: "보관", model: model)
                let archived = (try? await model.service.messages(folderID: "archive", search: nil))?.messages ?? []
                check("S-043 창에서 보관하면 보관함으로 가고 창이 닫힌다",
                      reader.closed && archived.contains { $0.subject == sent.subject })
            } else {
                check("S-043 데모 보낸 편지함에 메일이 있다", false)
            }
            let gone = MessageReader(messageID: "no-such-message")
            await gone.load(using: model)
            check("S-043 없는 메일은 창에 이유를 보인다", gone.message == nil && gone.failure != nil)
            model.selectedFolderID = "drafts"
            try? await Task.sleep(for: .seconds(0.5))
            if let draft = model.messages.first {
                await open(draft.id)
                await model.loadDetail()
                if case .compose = model.openTarget() { check("S-043 초안은 작성 창에서 이어서 쓴다", true) }
                else { check("S-043 초안은 작성 창에서 이어서 쓴다", false) }
            }

            // M15: VIP (S-045), 스마트 메일상자 (S-046)
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.6))
            if let m = model.messages.first(where: { $0.from?.emailAddress.address != nil }),
               let address = m.from?.emailAddress.address {
                model.removeVIP(address: address)
                model.editVIP(for: m)
                check("S-045 VIP로 지정하면 편집기가 그 사람으로 열린다", model.editingVIP?.address == address)
                var vip = model.editingVIP ?? VIP(address: address, name: "")
                vip.name = "중요한 분"
                vip.symbol = "crown.fill"
                model.saveVIP(vip)
                check("S-045 VIP는 이름·아이콘과 함께 저장된다",
                      model.mailboxes.vip(for: m)?.symbol == "crown.fill" && model.editingVIP == nil)
                let reloaded = MailboxStore(url: Store.directory.appending(path: "mailboxes.json"))
                check("S-045 VIP는 앱을 다시 열어도 남는다", reloaded.vip(address: address)?.name == "중요한 분")
                model.selectedFolderID = VirtualMailbox.id(forVIP: address)
                try? await Task.sleep(for: .seconds(0.6))
                check("S-045 VIP 메일상자에는 그 사람이 보낸 메일만",
                      !model.messages.isEmpty
                          && model.messages.allSatisfy { $0.from?.emailAddress.address?.lowercased() == address.lowercased() })
                check("S-045 목록 제목은 VIP 표시 이름", model.listTitle == "중요한 분")
                model.selectedFolderID = VirtualMailbox.allVIPsID
                try? await Task.sleep(for: .seconds(0.6))
                check("S-045 모든 VIP 상자에 VIP 메일이 모인다", !model.messages.isEmpty)
                model.removeVIP(address: address)
                check("S-045 VIP에서 빼면 사라진다", model.mailboxes.vip(for: m) == nil)
            } else {
                check("S-045 받은 편지함에 보낸 사람이 있는 메일", false)
            }

            let unreadAttach = SmartMailbox(name: "안 읽은 첨부", symbol: "paperclip", matchAll: true,
                                            conditions: [.init(field: .unread), .init(field: .attachments)])
            model.saveSmart(unreadAttach)
            try? await Task.sleep(for: .seconds(0.6))
            check("S-046 만들면 사이드바에 생기고 골라진다",
                  model.selectedFolderID == unreadAttach.id && model.mailboxes.smart.contains { $0.id == unreadAttach.id })
            check("S-046 모두 만족이면 모든 조건에 맞는 메일만",
                  model.messages.allSatisfy { $0.isUnread && $0.hasAttachments == true })
            let strictCount = model.messages.count
            var either = unreadAttach
            either.matchAll = false
            model.saveSmart(either)
            try? await Task.sleep(for: .seconds(0.6))
            check("S-046 하나라도 만족이면 더 넓게 모인다",
                  model.messages.count >= strictCount && !model.messages.isEmpty
                      && model.messages.allSatisfy { $0.isUnread || $0.hasAttachments == true })
            let sentBox = SmartMailbox(name: "보낸 메일", conditions: [.init(field: .folder, value: "sentitems")])
            model.saveSmart(sentBox)
            try? await Task.sleep(for: .seconds(0.6))
            check("S-046 폴더 조건은 그 폴더의 메일만",
                  !model.messages.isEmpty && model.messages.allSatisfy { $0.parentFolderId == "sentitems" })
            model.removeSmart(id: sentBox.id)
            model.removeSmart(id: unreadAttach.id)
            check("S-046 지우면 사이드바에서 빠지고 받은 편지함으로 돌아간다",
                  model.mailboxes.smart.isEmpty && model.selectedFolderID == "inbox")

            // M17: 맥 Mail 메뉴
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.6))
            if let m = model.messages.first(where: { !$0.isMeetingRequest }) {
                await open(m.id)
                let again = model.sendAgainDraft()
                check("M17 다시 보내기는 원본을 지우지 않는 새 메일", again != nil && again?.draftMessageID == nil
                          && again?.subject == (m.subject ?? ""))
                let asFile = model.forwardAsAttachmentDraft()
                check("M17 첨부 파일로 전달은 원본을 .eml로 붙인다",
                      asFile?.attachMessageFrom == m.id && asFile?.subject.hasPrefix("FW:") == true)
                let raw = (try? await model.service.mimeContent(id: m.id)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                check("M17 원본 보기는 헤더가 있는 MIME", raw.contains("Subject:") && raw.contains("From:"))
                await model.setImportanceSelected("high")
                check("M17 우선 순위를 높음으로", model.messages.first { $0.id == m.id }?.importance == "high")
                await model.setImportanceSelected("normal")
                model.toggleMuteSelected()
                check("M17 알림 비활성화", model.selectionIsMuted)
                model.toggleMuteSelected()
                check("M17 알림 활성화", !model.selectionIsMuted)
                let archiveBefore = (try? await model.service.messages(folderID: "archive", search: nil))?.messages.count ?? 0
                await model.copySelected(to: "archive")
                let archiveAfter = (try? await model.service.messages(folderID: "archive", search: nil))?.messages.count ?? 0
                check("M17 다음으로 복사는 원본을 남기고 복사본을 만든다",
                      archiveAfter == archiveBefore + 1 && model.messages.contains { $0.id == m.id })
                await model.moveSelected(to: "projects", undoManager: nil, undoName: "이동")
                check("M17 옮긴 폴더를 기억한다 (다시 이동)", model.lastMoveTarget?.id == "projects")
            }
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.6))
            await model.markAllReadInFolder()
            check("M17 모든 메시지를 읽음으로 표시", !model.messages.contains(where: \.isUnread))
            if let m = model.messages.first {
                await open(m.id)
                await model.toggleJunkSelected(undoManager: nil)
            }
            await model.emptyFolder(kind: "junkemail")
            let junkLeft = (try? await model.service.messages(folderID: "junkemail", search: nil))?.messages.count ?? -1
            check("M17 정크 메일 지우기", junkLeft == 0)
            model.selectedFolderID = "inbox"
            try? await Task.sleep(for: .seconds(0.3))
            let order = model.sidebarOrder
            model.selectAdjacentMailbox(1)
            check("M17 다음 메일상자로 이동",
                  order.firstIndex(of: model.selectedFolderID ?? "") == (order.firstIndex(of: "inbox") ?? 0) + 1)
            model.selectAdjacentMailbox(-1)
            check("M17 이전 메일상자로 이동", model.selectedFolderID == "inbox")
            let base = SmartMailbox(name: "복제 시험", conditions: [.init(field: .unread)])
            model.saveSmart(base)
            model.duplicateSmart(id: base.id)
            check("M17 스마트 메일상자 복제", model.mailboxes.smart.contains { $0.name == "복제 시험 사본" && $0.id != base.id })
            for box in model.mailboxes.smart { model.removeSmart(id: box.id) }

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
