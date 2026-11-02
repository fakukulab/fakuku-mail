# 용어집

화면 문구와 코드 이름은 이 표를 따른다.

| 화면에 쓰는 말 | 코드 이름 | 뜻 |
| --- | --- | --- |
| 메일, 메시지 | `MailMessage` | Graph의 message 하나. 메뉴와 창 제목은 "메시지", 그 밖에는 "메일" |
| 폴더 | `MailFolder` | Graph mailFolder |
| 새로운 메시지 | `ComposeKind.new` | 파일 메뉴 항목과 작성 창 제목 |
| 답장 / 전체 답장 / 전달 | `ComposeKind.reply`, `replyAll`, `forward` | |
| 작성 창 | `ComposeView` | 메일을 쓰는 창 |
| 서명 | `Signature` | HTML 조각. `data-signature` div로 본문에 들어감 |
| 기본 서명 | `SignatureRules` | 새 메일/답장/전달별로 처음 넣을 서명 |
| 첨부 보정 | `FixOptions` | 본문 이미지 → 첨부, 한글 파일명 인코딩 |
| 본문 이미지 | `ExtractedImage` (`contentID == nil`) | 서명 밖에 넣은 이미지. 보정 시 일반 첨부가 됨 |
| 인라인 이미지 | `ExtractedImage` (`contentID != nil`) | 서명 안 이미지. `cid:`로 본문에 남음 |
| 원격 이미지 | `MailContent.hasRemoteContent` | http(s)에서 불러오는 이미지. 기본은 차단 |
| 주소록 | `AddressBook`, `AddressBookStore` | 자동완성용, 주고받은 메일에서 모은 주소 (`recipients.json`) |
| 보관 | `MailService.move(to: "archive")` | |
| 지우기 | `MailService.move(to: "deleteditems")` | 완전 삭제가 아니라 지운 편지함으로 옮김 |
| 데모 모드 | `DemoMailService` | 로그인 없이 예시 메일로 도는 모드 (`APP_SEED=1`) |
| 초안, 임시 보관함 | `ComposeModel.saveDraft`, `MailService.saveDraft` | 쓰던 메일. ⌘S, 30초마다, 창을 닫을 때 저장 |
| 이어서 쓰기 | `AppModel.resumeDraft` | 저장된 초안을 작성 창으로 다시 열기 (⌘O) |
| 새 메일 알림 | `NewMailTracker`, `MailNotifier` | 지난 확인 이후 받은 편지함에 온 읽지 않은 메일 |
| Dock 배지 | `DockBadge`, `AppModel.updateBadge` | 받은 편지함의 읽지 않은 수 |
| 대화, 대화별로 정리 | `Conversation`, `AppModel.thread` | 같은 conversationId의 메일. 보기 메뉴에서 켜고 끔 (⌃⌘T) |
| 오프라인, 저장된 메일 | `MailCache`, `CachedMailService`, `AppModel.isOffline` | 네트워크가 없을 때 보여 주는 최근 목록과 본문 |
| 여러 통 선택 | `AppModel.selection`, `selectedIDs` | 목록에서 고른 줄들. 동작은 대화별이면 대화 전체에 |
| 이동 | `AppModel.move(_:to:)`, `MovePicker` | 다른 폴더로 옮기기. ⌘Z는 메일마다 원래 폴더로 |
| 깃발, 깃발 표시 | `FollowupFlag`, `FolderOrder.flaggedID` | 중요 표시와 그 메일을 모은 스마트 폴더 |
| 정크 메일로 표시 / 정크 아님 | `toggleJunkSelected` | 정크 메일 폴더로 / 받은 편지함으로 |
| 하위 폴더 | `MailFolder.depth`, `FolderOrder.tree` | 사이드바에서 들여 쓴 폴더 |
| 규칙 | `MessageRule`, `RuleDraft`, `RulesSettings` | Exchange 받은 편지함 서버 규칙 |
| 자동 응답 | `AutomaticReplies`, `AutoReplySettings` | 부재중 자동 회신 |
| 보내기 취소 | `ComposeModel.sendCountdown` | 보내기 뒤 정해 둔 초 동안 되돌리기 |
| 나중에 보내기 | `ScheduledSend`, `ComposeModel.schedule` | Exchange 지연 발송 |
| 회의 초대 | `MailEvent`, `MeetingBar` | 수락·미정·거절 (S-038 보류) |

| 메일상자 | Mailbox. 메뉴 막대의 메뉴 이름과 사이드바. "사서함"이라고 쓰지 않는다. |
| 메일상자 내보내기 | Export Mailbox (.mbox). 맥 Mail과 같은 말. |
| 메일상자 가져오기 | Import Mailboxes. 내 Mac의 .mbox·.eml을 메일 파일 창에서 연다 (서버에 올리지 않는다). |
| 메일 파일 | 내 Mac에 있는 .mbox·.eml 파일. "보관"은 보관 폴더(Archive)에만 쓴다. |
| 구독 취소 | Unsubscribe (List-Unsubscribe). "수신 거부"라고 쓰지 않는다. |
