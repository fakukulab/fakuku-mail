# Architecture review 2026-11-01 (end of M3)

Signal: end of milestone M3. Next milestone M4 has S-021 (per-account signature rules) and S-022 (save drafts).

Survey: 5,007 lines of Swift. Largest files: ComposeView 323, AppModel 318, RichTextEditor 284.
No file over 600 lines, no type over 400. No fix log yet. One protocol (`MailService`) with two adapters
(`GraphMailService`, `DemoMailService`), so the server seam is real. Pure rules live in `ExchangeMailKit`
and have unit tests. No duplicate `private struct` names. Result: the code is in good shape; nothing is Strong.

## Compose state as a model  [Worth exploring]

Files: Sources/ExchangeMail/Compose/ComposeView.swift (323 lines)
Signal: before a big feature (S-022 save drafts).
Problem: the compose window keeps its fields (to, cc, bcc, subject, files, forwarded, signature, fix toggle)
in `@State`, and `send()` assembles `ComposeSender.Input` inside the view. Saving a draft needs the same
fields and the same assembly, so S-022 would copy that code or grow the view past 400 lines.
Proposal:
```swift
@Observable final class ComposeModel {
    var to = "", cc = "", bcc = "", subject = ""
    var files: [URL] = []
    var forwarded: [FileAttachment] = []
    var signatureID: UUID?
    var fixEnabled = true
    init(draft: ComposeDraft, model: AppModel)
    func input(bodyHTML: String) -> ComposeSender.Input
    func send(bodyHTML: String) async throws      // build, send, record recipients
    func saveDraft(bodyHTML: String) async throws // S-022
}
```
Benefits: one place for "what is in this message"; the self-test can drive send and save without a window.
Proof of same behavior: self-test S-006/S-008/S-017 checks unchanged and passing; compose snapshot unchanged.
Plan: 1) add ComposeModel and move fields (no behavior change); 2) move send(); 3) S-022 on top.

## Testable Graph requests  [Worth exploring]

Files: Sources/ExchangeMail/Mail/MailService.swift (`GraphMailService.request`)
Signal: a dependency cannot be replaced in a test.
Problem: request building (paths, `$select`, `ConsistencyLevel`, `text/plain` MIME body for sendMail,
move destination) is only exercised against the live service. A typo shows up as a runtime 400.
Proposal: give `GraphMailService` a transport closure `(URLRequest) async throws -> (Data, HTTPURLResponse)`,
default `URLSession.shared`, and add Kit-side request builders that the unit tests check.
Benefits: request shapes get unit tests; error mapping (401/403/413/429) can be tested.
Proof: existing self-test (demo) unchanged; new unit tests for each request.
Plan: 1) transport closure; 2) move request builders to `ExchangeMailKit/GraphRequests.swift` with tests.

## Reader state out of AppModel  [Speculative]

Files: Sources/ExchangeMail/AppModel.swift (318 lines)
Signal: none yet (under 400 lines). AppModel owns folders, list, detail, moves, and drafts.
Problem: not hard to change today. It becomes a god model if threads, offline cache, or multi-account land.
Proposal: split `MessageReader` (detail, attachments, remote content, paging) when AppModel passes 400 lines.

## Top recommendation

Do **Compose state as a model** as the first step of S-022, since the draft feature needs it.
Nothing is `Strong`, so nothing was refactored in this check-in.

## Considered, not recommended

- Replacing the WKWebView editor with NSTextView: loses HTML signatures and font control the brief asks for.
- SwiftData for signatures: one small JSON file is simpler and already tested by the self-test.
- Splitting `ExchangeMailKit` into more targets: 1,300 lines do not need it.

## Follow-up at end of M4

- Compose state as a model: done in 1aa4d88 before S-022.
- Testable Graph requests: still Worth exploring.
- Reader state out of AppModel: AppModel is 335 lines; still Speculative.
