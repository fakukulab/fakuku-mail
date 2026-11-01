# Architecture

FAKUKU Mail (code name ExchangeMail) is one Swift package with three targets.

```text
ExchangeMail (app, main actor by default)  ──depends on──▶  ExchangeMailKit (pure rules, no SwiftUI)
ExchangeMailKitTests (Swift Testing)        ──depends on──▶  ExchangeMailKit
```

## ExchangeMailKit: rules with no UI

| File | What it decides |
| --- | --- |
| `FilenameEncoder` | NFC names, RFC 2047 words, RFC 2231 values and continuations, EUC-KR fallback |
| `HTMLProcessor` | which body images become attachments; signature and quote blocks stay inline |
| `MIMEBuilder` | the RFC 5322 message: headers, alternative/related/mixed parts, Graph size limit |
| `Addresses`, `AddressBook` | parsing recipient fields; recipient suggestions and completion |
| `AttachmentList` | adding attachments without duplicates or folders |
| `ComposeDraft` (`ReplyBuilder`) | reply/forward subject, recipients, quote, threading headers |
| `MailContent` | cid images to data URIs, remote content detection, CSP page, list dates |
| `MailModels` | Graph JSON types, folder order, date parsing |
| `OAuth` | PKCE, authorize URL, callback parsing, token types, Graph list queries |
| `Signature` | signatures, per-kind and per-account default rules, swapping the signature block |

## ExchangeMail: the app

- `AppModel` (@Observable): folders, list, detail, moves with undo, drafts for reply/forward.
  Owns `GraphAuth`, `SignatureStore`, `AddressBookStore`, a `MailService`, and the detail `PageScroller`.
- **Seam: `MailService`** with two adapters: `GraphMailService` (Microsoft Graph over URLSession) and
  `DemoMailService` (in-memory sample mailbox for demo mode, snapshots, and the self-test).
- `GraphAuth`: OAuth PKCE via ASWebAuthenticationSession, tokens in the Keychain, single-flight refresh.
- Compose: `ComposeModel` (@Observable: fields, attachments, signature swap, send, drafts),
  `ComposeView` (layout only), `RichTextController` (WKWebView editor),
  `ComposeSender` (fields to fixed MIME for sending, unfixed MIME for drafts).
- Drafts: `MailService.saveDraft` creates a new draft from MIME and deletes the old one
  (Graph cannot PATCH a message with MIME); `AppModel.resumeDraft` reopens one.
- Large mail (S-023): `MIMEBuilder.buildForGraph` moves the largest attachments out until the MIME request
  fits 4 MB. Those go through `MailService.uploadAttachment` (upload sessions, `UploadChunks`) on a draft,
  then `sendDraft`. `ComposeModel.sendLarge` deletes the draft if any step fails.
- Local files in `Store.directory`: `signatures.json`, `recipients.json`. Tokens in the Keychain.
- Menus read `MenuState` (an ObservableObject mirror), because SwiftUI Commands do not observe @Observable.

## Threads

Everything in the app target runs on the main actor. Network calls are `async` and suspend; JSON decoding
and MIME building are small enough to stay on the main actor. Revisit with the `performance` skill if
large attachments make sending feel slow.

## Reviews

- `docs/architecture-review-2026-11-01.md` (end of M3): no Strong candidates; compose model before S-022 (done).
- End of M4 (2026-11-01): largest file AppModel.swift at 335 lines; nothing Strong. Split `MessageReader`
  out of AppModel when it passes 400 lines or when threads/offline cache start.
