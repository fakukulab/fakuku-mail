# Fix log

## 2026-11-01 Build failed: non-Sendable 'any MailService' cannot exit main actor (SelfTest.swift)

Symptom: `swift build` stopped at SelfTest.swift: "non-Sendable type 'any MailService' of property 'service' cannot exit main actor-isolated context".
Cause: a local `async` function declared inside a `Task { }` closure does not inherit the main actor. It read `model.service`, which belongs to the main actor.
Fix: mark local async helpers `@MainActor` (`draftCount`, `open` in SelfTest.swift).
Rule: Always write `@MainActor` on local `async` functions that touch the model or views.

## 2026-11-01 Warning: '@preconcurrency' on ASWebAuthenticationPresentationContextProviding has no effect

Symptom: build warning in GraphAuth.swift.
Cause: the macOS 26 SDK already marks the protocol `@MainActor`.
Fix: plain conformance; the main-actor method is the witness.
Rule: Before adding `@preconcurrency` or `nonisolated` to an AppKit or WebKit delegate, check whether the SDK already marks it `@MainActor`.

## 2026-11-01 Archive could not be undone with Command-Z

Symptom: after Archive (menu, toolbar, or context menu), Command-Z did nothing.
Cause: `archiveSelected()` passed `undoManager: nil` to `moveSelected`; only Delete registered an undo.
Fix: every Archive caller passes the window's undo manager; the self-test now undoes both Archive and Delete.
Rule: Every destructive or moving action takes the window's UndoManager, and the self-test calls `undo()` on it.

## 2026-11-01 View > Organize by Conversation shortcut did nothing

Symptom: Option-Command-T did not toggle conversations.
Cause: Option-Command-T is macOS's Show/Hide Toolbar (from `ToolbarCommands`), which wins. The toggle also kept
`@AppStorage` inside `Commands`, which does not redraw the menu.
Fix: Control-Command-T; the App owns `@AppStorage("list.threaded")` and passes a binding to `MailCommands`.
Rule: Before picking a menu shortcut, check the standard View, Edit, and Window menu shortcuts; keep menu state in the App.

## 2026-11-01 Build failed: missing return in DemoMailService.conversation

Symptom: "missing return in instance method expected to return '[MailMessage]'" and "result of call to 'flatMap' is unused".
Cause: adding `try checkOnline()` as a first line turned a single-expression body into two statements, so the implicit return was gone.
Fix: `return store.flatMap { ... }`; checked every value-returning demo method has an explicit return.
Rule: When adding a line to a single-expression function body, add `return` to the expression.

## 2026-11-01 Printed mail had no header

Symptom: File > Print / Command-P printed the message body without the subject, from, to, and date header.
Cause: the menu item was enabled only with `hasMessage` (a list row selected and its detail loaded). When it was
disabled, Command-P went down the responder chain to the body WKWebView, whose NSView `print(_:)` prints only the body.
The header was also placed before a full HTML document's `<html>` instead of inside its `<body>`.
Fix: `MailWebView` overrides `printView(_:)` (AppKit's `print:` as Swift names it) and calls the app's header print; the menu is enabled whenever a message
is shown (`canPrint`); the header goes right inside `<body>`, and plain-text mail becomes HTML first.
Rule: When a web view shows content the app prints, override `printView(_:)` so every path prints the same thing. AppKit's `print:` is `printView(_:)` in Swift.

## 2026-11-02 Meeting answer showed "수락함" but the calendar did not change (investigating)

Symptom: on a same-org Teams invite, Accept showed "수락함", but the meeting did not appear in the Outlook calendar,
and Tentative afterwards did not change the label.
Cause (so far): the app set the label from the request's 2xx alone. Exchange answers meeting responses asynchronously,
so a 2xx does not prove the calendar changed, and the label hid the real server state.
Fix: after responding, the app reads the event back (1, 2, 3 s) and shows the server's responseStatus; if it does not
match, or the event cannot be found, it says so with the server state. Root cause on the server side still open.
Rule: Never show a server-side state the app only assumed; read it back and show what the server says.

## 2026-11-02 Build failed: main actor-isolated conformance of 'Category' to 'Decodable'

Symptom: "main actor-isolated conformance of 'Category' to 'Decodable' cannot satisfy conformance requirement for a 'Sendable' type parameter 'T'" in MailService.swift, plus a key path error after it.
Cause: the app target's default isolation is the main actor, so a struct declared there (even inside a function) has a main-actor Decodable conformance; `GraphList<T: Decodable & Sendable>` needs a nonisolated one.
Fix: `OutlookCategory` lives in ExchangeMailKit (no default isolation).
Rule: Types used as `GraphList<T>` or sent across actors go in ExchangeMailKit, not in the app target.

## 2026-11-02 도구 막대 사용자화를 누르면 앱이 꺼짐 (S-044)
- 증상: 메인 창에서 보기 > 도구 막대 사용자화…를 누르면 앱이 종료된다. 메시지 창은 괜찮다.
- 원인: 사용자화 시트는 도구 막대 항목을 창의 SwiftUI 환경 밖에서 다시 그린다. 필터·정렬 메뉴가
  `@Environment(AppModel.self)`로 모델을 읽어, 환경에 모델이 없어 멈췄다.
- 고침: `FilterMenu(model:)`, `SortMenu(model:)`로 모델을 직접 넘긴다. 도구 막대 항목 안의 뷰는 환경 객체를 읽지 않는다.
- 이전 단계: 열마다 따로 단 `.toolbar`는 창 전체의 사용자화를 껐다 → NavigationSplitView에 `.toolbar(id:)` 하나.
- 다시 꺼짐 (충돌 보고서): `NSToolbarConfigPanel`이 항목을 스냅숏할 때 `NSSearchToolbarItemView _updateWidthConstraints`가
  제약 예외를 던졌다. 앞의 원인 추정(환경 객체)은 틀렸다. 고침: `.searchable(placement: .sidebar)`로 검색 칸을 도구 막대에서 뺐다.
  규칙: 사용자화 도구 막대가 있는 창에는 `.searchable(placement: .toolbar)`를 쓰지 않는다.

## 2026-11-02 검색 범위가 두 번 보임, ⌥⌘F가 검색 칸에 들어가지 않음
- 증상: 사이드바의 `.searchable`이 "이 폴더 / 모든 폴더"를 두 번 그리고 구분선이 잘렸다. 직접 만든 도구 막대 검색 칸은 ⌥⌘F로 초점을 받지 못했다.
- 원인: 사이드바 배치의 시스템 검색 칸이 범위를 열마다 그린다. 도구 막대 항목은 창 본문과 다른 곳에 그려져 `@FocusState`가 닿지 않는다.
- 고침: `MailSearchField`(평범한 TextField + 범위 메뉴)를 본문 도구 막대 오른쪽 끝에 두고, ⌥⌘F는 `SearchFieldFocus`가 AppKit에서 placeholder "검색" 칸을 찾아 첫 응답자로 만든다.
- 규칙: 도구 막대 안의 컨트롤에 초점을 줄 때는 SwiftUI `@FocusState`에 기대지 않는다.

## 2026-11-02 엑셀에서 저장한 CSV를 가져오지 못함 (S-051)
- 증상: CADEX 방문객 CSV(UTF-8 BOM, CRLF)를 그룹에 가져오면 아무도 들어오지 않았다.
- 원인: Swift는 "\r\n"을 글자 하나(grapheme)로 본다. CSV 파서가 "\n"이나 "\r"만 줄바꿈으로 봐서 파일 전체가 한 줄이 되었다.
- 고침: 파싱 전에 "\r\n"과 "\r"을 "\n"으로 바꾼다. 테스트 `mergeCSVWindowsLineEndings`.
- 규칙: Swift에서 글자 단위로 줄을 나눌 때는 먼저 줄바꿈을 "\n"으로 맞춘다.

## 2026-11-02 "이 첨부는 파일이 아니라서 저장할 수 없습니다"
- 증상: 받은 메일의 첨부를 저장·열기하면 위 오류가 났다.
- 원인: Graph `GET /messages/{id}/attachments` 목록은 큰 파일과 첨부된 메일(itemAttachment)의 내용(contentBytes)을 빼고 준다.
  앱은 목록의 내용만 썼다. 같은 이유로 큰 첨부는 전달할 때 말없이 빠졌다.
- 고침: `AppModel.loadedAttachment`가 내용이 없으면 `GET /attachments/{aid}/$value`로 받아 채운다 (첨부된 메일은 .eml).
  미리 보기, 열기, 다운로드, 모두 다운로드, 전달이 모두 이 길을 쓴다. OneDrive 링크 첨부는 Outlook 웹으로 안내한다.
- 규칙: 첨부 내용은 목록에 있다고 가정하지 않는다.
