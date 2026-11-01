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
Fix: `MailWebView` overrides `print(_:)` and calls the app's header print; the menu is enabled whenever a message
is shown (`canPrint`); the header goes right inside `<body>`, and plain-text mail becomes HTML first.
Rule: When a web view shows content the app prints, override `print(_:)` so every path prints the same thing.
