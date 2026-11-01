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
        guard Store.isDemo, let demo = model.service as? DemoMailService else {
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

            // S-013
            // 열면 읽음이 되므로, 한 번 바꾸면 읽지 않음, 다시 바꾸면 읽음.
            let unreadOpen = model.selectedFolder?.unreadItemCount ?? 0
            await model.toggleReadSelected()
            check("S-013 읽지 않음으로 바꿀 수 있다", model.selectedMessage?.isUnread == true
                  && (model.selectedFolder?.unreadItemCount ?? 0) == unreadOpen + 1)
            await model.toggleReadSelected()
            check("S-013 다시 바꾸면 읽음", model.selectedMessage?.isRead == true
                  && (model.selectedFolder?.unreadItemCount ?? 0) == unreadOpen)

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

            // S-014
            model.searchText = "견적"
            await model.loadMessages()
            check("S-014 검색은 맞는 메일만 보인다",
                  !model.messages.isEmpty && model.messages.allSatisfy { $0.title.contains("견적") })
            model.searchText = ""
            await model.loadMessages()
            check("S-014 검색어를 지우면 원래 목록", model.messages.count == countBefore - 2)

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
