# FAKUKU Mail (code name: ExchangeMail)

The visible name is "FAKUKU Mail" (`Info.plist.in`, `build.sh` `display`, window title).
Everything else keeps the code name `ExchangeMail`. Keep the bundle id: the Azure redirect URI depends on it.

A native macOS mail client in SwiftUI for Microsoft Exchange Online.
Mail stays on the server (Microsoft Graph). Local data: signatures in
`~/Library/Application Support/ExchangeMail/signatures.json`, VIPs and smart mailboxes in `.../ExchangeMail/mailboxes.json`, an offline cache of recent mail in
`.../ExchangeMail/cache/` (cleared on sign-out), tokens in the Keychain, settings in UserDefaults. UI language: Korean (`docs/GLOSSARY.md` for words).

## Layout

- `Sources/ExchangeMail/` the app. `App.swift` has the windows, menus, and the data location (`Store`).
  `AppModel.swift` app state. `Auth/` OAuth PKCE and Keychain. `Mail/` the `MailService` protocol,
  `GraphMailService` (real) and `DemoMailService` (sample mailbox). `Compose/` the compose window,
  the WKWebView rich text editor, and `ComposeSender` (input -> fixed MIME). `Views/` list, detail, sign-in, signatures.
- `Sources/ExchangeMailKit/` rules with no SwiftUI: attachment fix (FilenameEncoder, HTMLProcessor, MIMEBuilder),
  Graph models, OAuth, reply drafts, mail content safety. Tests in `Tests/ExchangeMailKitTests/`.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs, and installs `~/Applications/FAKUKU Mail.app` (executable `ExchangeMail`).
- `Icon/AppIcon.icon` the app icon, an Icon Composer file (JSON plus SVG layers). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG.
- `docs/` the brief, the screen index, and the user stories, when they exist.

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
- Unit tests: `swift test --scratch-path ~/Library/Developer/ExchangeMail/test-build`.
- Demo mode: `APP_STORE=<dir in /tmp> APP_SEED=1` runs a sample mailbox with no sign-in and no network.
  `tools/demo.sh` opens it. Snapshots and the self-test always run in demo mode.
- Self-test (the app's real functions on the demo mailbox and a /tmp store): `tools/selftest.sh`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots with sample data and look at them: `tools/snap.sh`.
  It writes `/tmp/ExchangeMail-shots/<page>-light.png` and `-dark.png` for inbox, sentitems, drafts, archive,
  deleteditems, signin, compose, message, `vip-editor` and `smart-editor` (page `mailboxes`), and `settings-<tab>-light.png` and `-dark.png` for every Settings tab, then quits.
  `APP_SNAPSHOT_PAGES=inbox,compose,settings tools/snap.sh` limits the pages.
  For a panel, sheet, or popover, add a capture to `Snapshot.swift` like the Settings loop.
- Snapshots, demo mode, and the self-test refuse to run without `APP_STORE` in /tmp.
- Never test against a real Exchange account or the real `~/Library/Application Support/ExchangeMail/`.
- Graph rules: sending is `POST /me/sendMail` with the base64 MIME as `text/plain` (4 MB request limit);
  moving a message changes its id; `$search` cannot be combined with `$orderby`.
- Received HTML is untrusted: JavaScript off, navigation other than link clicks cancelled (`Views/HTMLView.swift`, `MailContent`).
  Remote content follows `RemoteContent`: with Mail activity protection (default) trackers are removed and other remote
  images load through `fakuku-proxy:` (`TrackingProtection`, `ProxyImageLoader`: no cookies, no referer); otherwise CSP blocks them.
- Then check the grid: `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/ExchangeMail-shots/*-layout.json`. Both print PASS.
- A change is done when the build has no errors, the grid checks pass, and you looked at the light and dark snapshots.

## Design rules

- Use Apple's controls and system styles. Only the accent color is custom: `UI/Theme.swift` (`ThemeStore.defaultID`). People change it in Settings > 일반 (강조 색); light or dark mode follows the Mac.
- Views use `.tint`, `Palette.accent`, `Palette.accentText` (accent-colored text), and `Palette.onAccent` (text on an accent fill). Never hard-code colors, radii, or durations in views.
- Compare accents: add `APP_ACCENT=<id>` to the snapshot command.
- Spacing comes from `Space` in `UI/Grid.swift`, on a 4 pt grid. Mark custom pages and cards with `.gridArea` and `.gridProbe`.
- Windows open calm: `.noInitialFocus()` on every window and sheet (no focus ring or selected text on open), `.fitsContent()` on sheets (no scroll bar with nothing to scroll); every Settings tab has the same fixed size (`SettingsView.size`) so the window does not jump between tabs. System scroll bars. Both in `UI/WindowBehavior.swift`.
- Settings: Mail's tabs in `SettingsView.swift` (일반, 계정, 정크 메일, 보기, 작성, 서명, 규칙, 자동 응답, 알림).
  Each is one `.formStyle(.columns)` Form: right-aligned labels ending in a colon, controls in the right column,
  notes as `SettingsNote`. Signatures, rules, and auto reply edit lists and keep their own layouts. Add a case to `SettingsTab` for a new tab.
- Window chrome (title bar, toolbar, sidebar, menus, sheets) stays system. Buttons use system styles, like `.borderedProminent`.
- Colors: `.primary`, `.secondary`, `.tint`, and system colors. Never fixed grays or white for text.
- Every action has a menu bar item and a keyboard shortcut.
- `Label` for icon and text pairs. SF Symbols for icons.
- `ContentUnavailableView` for empty states.
- Liquid Glass belongs to floating controls only, never to content.

## Skills

The bama plugin has a skill for each step: `mac-design` (design rules),
`design-system` (accent and tokens), `layout-grid`, `ux-design`,
`swift-swiftui`, `os-integrations`, `performance`, `build-and-verify`,
`test-mac-app`, `app-icon`, `user-stories`, and `improve-loop`. Use them.

## Git

- Commit after each working change, with a message that says what the user can now do.
