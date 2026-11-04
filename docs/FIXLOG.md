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

## 2026-11-02 깃발 색 메뉴가 글자만, 그다음 강조색 한 가지로 보임
- 증상: 깃발 색 메뉴에 아이콘이 안 보이다가, 보이게 한 뒤에는 일곱 깃발이 모두 강조색이었다.
- 원인: macOS 메뉴는 Label의 아이콘을 기본으로 숨기고(`.labelStyle(.titleAndIcon)` 필요), SF Symbol 그림은 모양만 써서 강조색으로 덧칠한다.
- 고침: 색 깃발을 비트맵(NSBitmapImageRep)으로 한 번 그려 `Image(nsImage:)`로 넘긴다 (`FlagColor.flagImage`).
- 규칙: 메뉴에서 색이 남아야 하는 아이콘은 기호가 아닌 비트맵으로 넘긴다.

## 2026-11-03 Siri 명령(App Intents) 메타데이터를 swift build로 만들기
- 증상: 빌드는 되지만 Siri·단축어에 명령이 안 보임. Metadata.appintents가 앱에 없었다.
- 원인 1: `-emit-const-values`만 주면 전체 모듈 최적화 빌드에서 .swiftconstvalues가 생기지 않는다 → `-emit-const-values-path`로 자리를 정한다.
- 원인 2: `appintentsmetadataprocessor`는 링커의 dependency_info로 AppIntents.framework 링크 여부를 본다 → `-Xlinker -dependency_info`.
- 원인 3: 빌드 결과 폴더는 심볼릭 링크라 `find -L`로 찾는다.
- 고침: build.sh가 위 옵션으로 빌드하고 tools/make_intents.sh가 메타데이터를 만든다 (Xcode 27B52에서 확인).
- 규칙: 매개변수(@Parameter)가 있는 인텐트는 nonisolated struct로 둘 수 없다 → `@preconcurrency AppIntent`.

## 2026-11-03 나의 Mac에 상자를 고르면 앱이 꺼짐 (도구 막대)
- 증상: 메일상자를 가져와 고르자마자 종료. 충돌 위치 `-[NSToolbarItemViewer _configurePositioningConstraints]` → `-[__NSArrayM insertObject:atIndex:]`.
- 원인: 가운데·오른쪽 열의 뷰를 `if`로 통째로 바꿨다. 그 열에 달린 사용자화 도구 막대(`.toolbar(id: "mail")`) 항목이 빠졌다 들어가며 AppKit이 도구 막대를 다시 짜다 예외.
- 고침: 열 뷰(MessageListView, MessageDetailView)는 그대로 두고 나의 Mac에 화면을 `.overlay`로 덮는다. 제목은 model.listTitle.
- 규칙: `.toolbar(id:)`가 달린 열이나 창의 뷰는 조건에 따라 바꾸지 않는다. 안의 내용만 바꾸거나 덮는다.

## 2026-11-03 나의 Mac에 상자를 열 때마다 다시 읽음
- 증상: 상자를 고를 때마다 "메일을 읽는 중…"이 반복되고 느리다 (상자가 여러 개일 때 특히).
- 원인: 열 때마다 mbox 전체를 첨부까지 해석했고, 메모리에 기억하는 상자는 최근 4개뿐이었다. 목록 미리보기도 그릴 때마다 HTML에서 뽑았다.
- 고침: 가져올 때 목록 색인(<id>.index-v1.json: 요약, 미리보기, 검색 글, 파일 안 위치)을 만들어 두고 열 때는 색인만 읽는다.
  본문·첨부는 고른 메일 한 통만 그 위치에서 읽는다 (ArchiveIndex). 예전에 가져온 상자는 처음 열 때 한 번 색인을 만든다.

## 2026-11-03 메일 여는 속도
- 본문 JSON(큰 HTML)과 50통 목록 해석이 메인 스레드에서 돌아 큰 메일을 열 때 화면이 잠깐 멈췄다 → `decodedOffMain` (GraphMailService).
- 같은 메일을 다시 열어도 매번 서버를 기다렸다 → 연 메일 60통을 메모리에 기억 (`DetailCache`, AppModel+Prefetch). 읽음·깃발은 목록 줄 값으로 덮는다.
- ↓↑로 넘길 때마다 기다렸다 → 메일을 열면 다음 두 통과 이전 한 통을 미리 받는다.
- 본문을 받은 뒤에야 첨부 목록을 요청했다 → 목록 줄에 첨부 표시가 있으면 동시에 요청.
- 같은 대화 안을 오갈 때마다 대화를 다시 물었다 → 1분 동안 기억. 옮기기·지우기·깃발·중요도·복사 뒤에는 비운다.

## 2026-11-03 목록 스크롤이 끊김
- 목록이 다시 그려질 때마다 수백 통을 대화로 다시 묶었다(제목마다 정규식) → 메일·관련 메일·정렬이 그대로면 지난 결과를 쓴다 (`conversationMemo`). 정규식은 제목에 "["가 있을 때만.
- 줄마다 @AppStorage 두 개(미리보기 줄 수, 볼드체)를 따로 지켜봤다 → 목록이 한 번 읽어 넘긴다.
- 맨 끝 줄이 보여야 다음 쪽을 불러 끝에서 멈칫했다 → 끝에서 열 줄 전에 미리 부른다.

## 2026-11-03 메일을 누를 때마다 본문과 대화 목록이 깜빡임
- 원인 1: 본문 열이 `detail.id == displayedMessageID`일 때만 본문을 그려, 새 메일을 받는 동안(기억해 둔 메일도 Task 한 번) 진행 표시로 바뀌었다.
- 원인 2: 메일을 고를 때마다 `thread = []`로 대화 목록을 지웠다가 다시 채웠다 (같은 대화 안에서 옮겨도).
- 고침: 새 본문이 올 때까지 지금 메일을 그대로 둔다. 기억해 둔 메일은 didSet 안에서 바로 바꾼다 (`showCachedDetail`).
  같은 대화면 대화 목록을 지우지 않는다.

## 2026-11-03 본문 창 크기를 바꿀 때 느림
- 본문 열은 창·열 크기를 바꾸는 동안 수십 번 다시 그려진다. 그때마다 본문 HTML 전체를 훑는 일이 되풀이됐다:
  원격 그림 검사(정규식 여러 개), 캐시 키의 `content.count`(글자 수 세기는 전체를 훑는다), `page.html + css`(큰 문자열 새로 만들기 →
  웹 보기도 전체를 비교), 가져온 메일은 본문 그림을 data: 주소로 다시 만들기.
- 고침: 원격 그림 검사는 메일마다 한 번(`remoteContentMemo`), 키는 `utf8.count`, 서식까지 붙인 문서를 캐시해 같은 문자열을 넘긴다
  (`protectedPage(css:)`), 가져온 메일 문서도 캐시 (`ArchivedPageCache`).
- 규칙: 뷰 body에서 본문 크기에 비례하는 일을 하지 않는다. 필요하면 메일 id(와 크기)로 기억한다.

## 2026-11-03 대화 묶음의 수가 실제 대화와 다름
- 목록 줄의 수: 이 폴더에서 불러온 메일 + 보낸 편지함 최근 메일 중 같은 대화 + 제목으로 합친 대화. "관련된 메시지 포함"을 꺼도 다른 폴더를 셌다.
- 본문 위 대화 목록: 서버의 대화 전체(지운 편지함·임시 보관함·정크 포함), 제목으로 합친 다른 대화는 빠짐.
- 고침: 같은 규칙으로 센다. 대화 목록은 목록 줄이 합친 대화를 모두 가져오고, 임시 보관함·지운 편지함·정크·보낼 편지함은 양쪽 모두 빼며
  (그 폴더를 보고 있을 때는 넣는다), 설정을 끄면 양쪽 모두 이 폴더만. 대화를 열면 목록 줄의 수를 확인한 수로 바꾼다 (`threadCounts`).

## 2026-11-04 "요청이 너무 많습니다" (429)
- 원인: Exchange Online은 사서함 하나에 동시에 4개 요청까지 받는다. 메일 하나를 열 때 본문·첨부·대화·미리 받기 3통(동시에)·본문 그림마다 하나씩을
  한꺼번에 띄워 한도를 넘었다. 429가 오면 바로 오류 창을 띄웠다.
- 고침: 모든 Graph 요청이 `RequestGate`(동시 4개)를 지난다. 429·503이면 Retry-After만큼(없으면 2·4·8초) 쉬고 세 번까지 조용히 다시 보낸다.
  막힌 뒤 2분 동안 미리 받기를 쉬고(`GraphThrottle`), 미리 받기는 한 통씩 차례로, 관문이 바쁘면 기다린다.
- 규칙: 새 기능이 Graph 요청을 늘리면 동시에 몇 개가 나가는지 본다. 급하지 않은 요청은 `GraphThrottle.isCalm`과 `gate.isBusy`를 본다.
