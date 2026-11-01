# ExchangeMail

Microsoft Exchange Online 계정을 쓰는 한국 사용자를 위한 맥용 메일 클라이언트.
맥 Mail처럼 생겼고, 한글 첨부 파일명과 본문 이미지 문제를 보내기 전에 바로잡는다.

## Replaces
맥 Mail + Exchange 조합(한글 첨부 파일명 깨짐, 본문 이미지가 인라인으로만 나감),
그리고 이를 우회하던 별도 "첨부도우미" 도구와 SMTP 릴레이.

## Main jobs
1. 폴더별로 받은 메일을 훑어보고 읽는다 (폴더 / 목록 / 본문 3단).
2. 새 메일·답장·전체 답장·전달을 쓰고, 첨부 보정이 적용된 MIME으로 보낸다.
3. 서명 여러 개를 만들고 꾸민 뒤, 상황별 기본 서명을 정한다.

## Data
- MailFolder (원격, Graph): id, 이름, 안 읽은 수, 전체 수
- MailMessage (원격, Graph): id, internetMessageId, 제목, 보낸 사람, 받는 사람, 참조, 날짜, 미리보기, 본문, 읽음, 첨부 여부
- Attachment (원격, Graph): 이름, 형식, 크기, 인라인 여부, contentId, 내용
- Signature (로컬 JSON): 이름, HTML, 수정 시각
- SignatureRules (로컬 JSON): 새 메일/답장/전달별 기본 서명, 계정별 규칙
- 토큰: Keychain. 설정값(클라이언트 ID, 테넌트, 첨부 보정 기본값): UserDefaults

## Shape
사이드바 창(NavigationSplitView 3단) + 메시지 작성 창(여러 개) + 설정 창. macOS 26 이상.
인터넷 필요: Microsoft Graph(`graph.microsoft.com`)와 로그인(`login.microsoftonline.com`).
계정 1개(Microsoft 365 / Exchange Online, OAuth2 PKCE). 메일은 서버에만 있고 로컬 캐시 없음.
로그인 없이 볼 수 있는 데모 모드(`APP_SEED=1`)로 스냅숏과 셀프 테스트를 돌린다. (decided by the agent)

## System hooks
메뉴 막대 명령과 단축키(⌘N 새 메시지, ⌘R 답장, ⇧⌘R 전체 답장, ⇧⌘F 전달, ⇧⌘N 받은 메일 가져오기).
링크는 기본 브라우저로 연다. 그 밖에는 없음. (decided by the agent)

## Reference
맥 Mail (3단 레이아웃, 툴바 배치, 단축키). 첨부 README의 기획안 F1~F3, F5, F6, F9, F10.

## Look
맥 기본 모양 + 시스템 강조색. 맥 Mail과 나란히 써도 어색하지 않아야 한다. UI 언어는 한국어. (decided by the agent)

## Design plan
1. **Archetype**: 사이드바 창 + 작성 창(WindowGroup) + 설정 창.
2. **Information architecture**: 사이드바 = 메일 폴더(받은 편지함, 임시 보관함, 보낸 편지함, 보관, 정크, 지운 편지함, 그 밖의 폴더). 한 단계.
3. **Command map**: 파일 > 새로운 메시지 ⌘N. 메시지 > 답장 ⌘R, 전체 답장 ⇧⌘R, 전달 ⇧⌘F, 보관 ⌃⌘A, 지우기(목록에서 Delete), 읽음/안 읽음 표시 ⇧⌘U, 받은 메일 가져오기 ⇧⌘N. 원격 이미지 불러오기 ⇧⌘I. 작성 창: 보내기 ⇧⌘D, 파일 첨부 ⇧⌘A.
4. **Empty states**: 로그인 전 = 로그인 화면. 폴더가 비면 "메시지 없음". 선택 없음 = "메시지를 선택하세요". 서명이 없으면 "서명 없음 + 추가 버튼".
5. **Feeling**: 믿음직함. 보내기 전에 무엇이 어떻게 나갈지 보여 준다.

## Not in version one
- 여러 계정, 대화(스레드) 보기, 오프라인 캐시, 알림
- 초안 저장, 받는 사람 자동완성(주소록), 규칙/필터
- 업데이트(Sparkle)·공증 배포 (기획안 7장)
