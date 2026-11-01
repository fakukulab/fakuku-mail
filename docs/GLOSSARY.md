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
