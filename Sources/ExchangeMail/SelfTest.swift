import AppKit
import ExchangeMailKit
import Foundation

/// Self-test for agents: runs the app's real functions on the demo mailbox and a /tmp store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/ExchangeMail-self ~/Applications/ExchangeMail.app/Contents/MacOS/ExchangeMail --selftest
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
        func open(_ id: String) async {
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
