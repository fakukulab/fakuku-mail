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
