# ExchangeMail stories

Status 규칙: `todo`, `doing`, `done`, `dropped`.
이 저장소의 첫 코드는 Swift 컴파일러가 없는 Linux 컨테이너에서 작성되었다.
코드가 들어갔지만 맥에서 빌드·스냅숏·셀프 테스트를 아직 돌리지 않은 스토리는 `doing`이다.
맥에서 `./build.sh && tools/selftest.sh && tools/snap.sh`가 통과하면 `done`으로 바꾼다.

스냅숏 페이지 이름: `signin`, `inbox`, `sentitems`, `drafts`, `archive`, `deleteditems`, `compose`,
`settings-account`, `settings-signatures`, `settings-attachments`, `settings-appearance`.

## M1 Core loop: 로그인, 읽기, 보정해서 보내기

### S-001 Microsoft 계정으로 로그인
As the user, 로그인 화면에 Azure 클라이언트 ID를 넣고 "Microsoft로 로그인"을 눌러 Exchange 계정으로 들어간다.
Screens: signin
Acceptance:
- [snap] 로그인 전에는 로그인 화면만 보인다: 제목, 설명, 클라이언트 ID·테넌트 칸, 버튼.
- [unit] 인증 URL에 client_id, response_type=code, redirect_uri=`msauth.<번들ID>://auth`, PKCE S256 challenge, state가 들어간다.
- [unit] PKCE challenge는 verifier의 SHA-256을 base64url(패딩 없음)로 쓴 값이다.
- [manual] 로그인 후 토큰이 Keychain에 저장되고, 앱을 다시 열어도 로그인 상태가 유지된다.
- [manual] 리프레시 토큰이 만료되면 오류 대신 로그인 화면으로 돌아간다.
UX: 버튼 이름은 "Microsoft로 로그인". 클라이언트 ID가 비면 버튼이 꺼지고, 칸 아래에 "README의 Azure 앱 등록 참고"라는 도움말이 있다.
Status: doing

### S-002 사이드바에서 폴더 고르기
As the user, 사이드바에서 폴더를 눌러 그 폴더의 메일 목록을 본다.
Screens: inbox, sentitems
Depends: S-001
Acceptance:
- [snap] 받은 편지함, 임시 보관함, 보낸 편지함, 보관, 정크 메일, 지운 편지함 순서이고, 각자 맞는 SF Symbol이 있다.
- [snap] 안 읽은 메일이 있는 폴더에 숫자 배지가 있다.
- [unit] 폴더 정렬은 영어·한국어 표시 이름 모두에서 같은 순서다.
- [self] 시작하면 받은 편지함이 선택된다.
Status: doing

### S-003 메일 목록 훑어보기
As the user, 목록에서 보낸 사람, 제목, 날짜, 미리보기, 첨부 표시, 안 읽음 점을 본다.
Screens: inbox
Depends: S-002
Acceptance:
- [snap] 안 읽은 메일은 파란 점과 굵은 보낸 사람 이름으로 보인다.
- [snap] 오늘 받은 메일은 시각, 그 전 메일은 날짜를 보인다.
- [self] 50개를 넘는 폴더에서 목록 끝에 닿으면 다음 쪽을 더 불러온다.
Status: doing

### S-004 메일 읽기
As the user, 목록에서 메일을 골라 본문, 받는 사람, 참조, 첨부를 본다.
Screens: inbox
Depends: S-003
Acceptance:
- [snap] 머리글에 제목, 보낸 사람, 받는 사람, 참조, 날짜가 있고 그 아래 HTML 본문이 있다.
- [unit] 본문의 `cid:` 이미지는 인라인 첨부의 data URI로 바뀌어 보인다.
- [unit] 원격 이미지가 있는 본문은 차단 정책(CSP)과 함께 표시되고, 차단 막대가 보인다.
- [self] 안 읽은 메일을 열면 읽음으로 바뀐다.
- [manual] 본문 링크를 누르면 기본 브라우저가 열린다. 본문 안 JavaScript는 돌지 않는다.
UX: 차단 막대 문구는 "원격 이미지를 차단했습니다." 버튼은 "불러오기".
Status: doing

### S-005 첨부파일 저장
As the user, 받은 메일의 첨부 칩을 눌러 파일로 저장한다.
Screens: inbox
Depends: S-004
Acceptance:
- [unit] 저장 이름은 NFC로 정규화되고 `/`, `\`, 제어 문자가 빠진다.
- [manual] 저장 패널이 열리고, 고른 위치에 원본과 같은 바이트가 쓰인다.
Status: doing

### S-006 새 메일 쓰고 보정해서 보내기
As the user, ⌘N으로 작성 창을 열어 받는 사람, 참조, 숨은 참조, 제목, 본문, 첨부를 넣고 ⇧⌘D로 보낸다.
Screens: compose
Acceptance:
- [unit] 본문에 넣은 이미지는 일반 첨부로 나가고, 서명 안의 이미지는 `cid:` 인라인으로 남는다 (F1, F2).
- [unit] 한글 파일명은 NFC로 바뀌고 RFC 2047 B와 RFC 2231 `filename*`이 함께 기록된다 (F3, F5).
- [unit] EUC-KR 옵션을 켜면 CP949로 표현할 수 없는 글자가 있을 때 UTF-8로 되돌아간다 (F6).
- [unit] 제목과 보낸 사람 이름이 RFC 2047로 인코딩되고 한 줄이 76자를 넘지 않는다.
- [unit] 받는 사람 칸의 `홍길동 <a@b.com>; c@d.com` 형식을 주소 목록으로 읽고, 잘못된 주소는 보내기 전에 알린다.
- [self] 데모 모드에서 보내면 만든 MIME이 데모 서비스에 기록되고 작성 창이 닫힌다.
- [manual] 실제 계정에서 보낸 메일을 Outlook(Windows)에서 열면 첨부 이름이 한글로 보인다.
UX: 보내기 버튼은 툴바의 유일한 강조 버튼. 보내는 중에는 진행 표시와 함께 꺼진다. 실패하면 창을 닫지 않고 오류를 알린다.
Status: doing

### S-007 답장, 전체 답장, 전달
As the user, 메일을 고른 채 ⌘R, ⇧⌘R, ⇧⌘F로 인용문이 들어간 작성 창을 연다.
Screens: compose
Depends: S-004, S-006
Acceptance:
- [unit] 답장 제목은 "RE: "를 한 번만 붙이고, "회신:", "RE:", "FW:", "전달:" 접두어를 알아본다.
- [unit] 전체 답장은 내 주소를 빼고, 보낸 사람은 받는 사람, 나머지는 참조로 넣는다.
- [unit] 답장 MIME에 `In-Reply-To`와 `References`가 원본 internetMessageId로 들어간다.
- [unit] 전달은 원본 첨부(인라인 제외)를 함께 보낸다.
- [snap] 인용문은 "<날짜>, <보낸 사람> 님이 작성:" 아래 왼쪽 선이 있는 블록이다.
Status: doing

### S-008 메일마다 첨부 보정 끄고 켜기
As the user, 작성 창의 "첨부 보정" 체크로 이번 메일에만 보정을 끄거나 켜고, 첨부가 어떤 이름으로 나갈지 본다.
Screens: compose
Depends: S-006
Acceptance:
- [snap] 첨부 칩은 보정 후 나갈 이름(NFC)을 보이고, 본문 이미지를 첨부로 뺄 때는 "본문 이미지 n개가 첨부로 나갑니다"라는 안내가 보인다.
- [unit] 보정을 끄면 본문 이미지는 인라인으로 남고 EUC-KR은 쓰지 않는다. 파일명 NFC와 RFC 2231은 항상 적용된다.
Status: doing

### S-009 서명 여러 개 만들기
As the user, 설정 > 서명에서 서명을 추가, 이름 변경, 삭제하고 글꼴, 크기, 색, 정렬, 링크, 이미지로 꾸미거나 HTML 소스를 직접 고친다.
Screens: settings-signatures
Acceptance:
- [snap] 왼쪽은 서명 목록과 +/− 버튼, 오른쪽은 이름 칸, 서식 막대, 편집기다.
- [self] 서명을 추가하면 목록 끝에 선택된 채 생기고, 지우면 그 서명을 쓰던 기본 규칙도 지워진다.
- [self] 서명은 앱을 다시 열어도 남는다 (`signatures.json`).
Status: doing

### S-010 상황별 기본 서명과 작성 중 전환
As the user, 새 메일, 답장, 전달마다 기본 서명을 정하고, 작성 창에서 서명 메뉴로 언제든 바꾼다.
Screens: settings-signatures, compose
Depends: S-009, S-006
Acceptance:
- [unit] 계정 규칙이 전역 규칙보다 앞서고, "없음"을 고른 규칙은 서명을 넣지 않는다.
- [unit] 서명을 바꾸면 본문의 서명 블록 한 개만 바뀌고 인용문 앞자리를 지킨다.
- [snap] 작성 창이 열리면 기본 서명이 본문 빈 줄 아래, 인용문 위에 들어가 있다.
Status: doing

## M2 Organize: 정리와 찾기

### S-011 보관하기
As the user, ⌃⌘A나 툴바 버튼으로 고른 메일을 보관 폴더로 옮긴다.
Acceptance:
- [self] 옮긴 메일은 목록에서 사라지고 다음 메일이 선택된다.
Status: doing

### S-012 지우기
As the user, 목록에서 Delete를 누르거나 툴바 휴지통으로 메일을 지운 편지함으로 옮긴다.
Acceptance:
- [self] 옮긴 메일은 목록에서 사라지고 다음 메일이 선택된다.
- [manual] ⌘Z로 되돌리면 원래 폴더로 돌아온다.
Status: doing

### S-013 읽음/안 읽음 표시
As the user, ⇧⌘U나 컨텍스트 메뉴로 읽음 상태를 바꾼다.
Acceptance:
- [self] 목록의 점과 폴더 배지 숫자가 같이 바뀐다.
Status: doing

### S-014 메일 검색
As the user, 툴바 검색 칸에 단어를 넣고 Return으로 현재 폴더를 검색한다.
Acceptance:
- [unit] 검색 요청은 `$search`와 `ConsistencyLevel: eventual`을 쓰고 `$orderby`는 쓰지 않는다.
- [self] 검색어를 지우면 원래 목록이 돌아온다.
Status: doing

### S-015 받은 메일 가져오기
As the user, ⇧⌘N이나 새로고침 버튼으로 폴더와 목록을 다시 불러온다. 앱이 앞에 있으면 2분마다 저절로 가져온다.
Acceptance:
- [self] 새로고침 뒤에도 선택한 폴더와 메일이 유지된다.
Status: doing

### S-016 원격 이미지 불러오기
As the user, 차단 막대의 "불러오기"나 보기 메뉴로 이 메일의 원격 이미지를 불러온다.
Depends: S-004
Acceptance:
- [unit] 허용한 메일은 원격 `img-src`를 허용하는 정책으로 다시 그린다.
- [manual] 다른 메일로 옮기면 다시 차단된다.
Status: doing

## M3 Speed: 손이 빠른 작업

### S-017 첨부를 끌어다 놓기
As the user, Finder에서 파일을 작성 창으로 끌어 첨부한다.
Screens: compose
Depends: S-006
Acceptance:
- [manual] 파일을 작성 창 어디에 놓아도(본문 편집기 위 포함) 첨부 칩이 생기고, 본문에 file:// 링크나 그림이 들어가지 않는다.
- [manual] 끌고 있는 동안 창 가장자리에 강조색 테두리가 보인다.
- [unit] 같은 파일(NFD/NFC 이름 포함)은 한 번만 들어간다.
- [self] 폴더는 건너뛰고 "폴더는 첨부할 수 없습니다" 알림을 띄운다.
- [manual] 설정 > 서명 편집기에 그림 파일을 놓으면 서명 안에 그림이 들어간다.
UX: 놓는 곳은 따로 표시하지 않는다(창 전체). 끄는 동안만 테두리. 알림 제목은 "첨부할 수 없습니다".
Status: doing (코드 완료, 맥 빌드·직접 끌어 보기 대기)

### S-018 받는 사람 자동완성
As the user, 받는 사람·참조·숨은 참조 칸에 이름이나 주소 일부를 치면, 주고받은 메일의 주소 목록에서 골라 넣는다.
Screens: compose
Depends: S-006
Acceptance:
- [unit] 쉼표·세미콜론 뒤 마지막 항목만 찾고, 이미 칸에 있는 주소와 내 주소는 빼며, 많이 보낸 사람 → 이름이 그대로 시작하는 사람 순이다.
- [unit] 고르면 마지막 항목이 `이름 <주소>, `로 바뀐다 (따옴표 안 쉼표는 구분자가 아님).
- [self] 데모 받은 편지함을 읽으면 "민지"로 김민지 주소가 나온다.
- [manual] 제안 목록은 시스템 자동완성 팝업이고 ↑↓와 Return으로 고른다.
UX: 제안 줄은 사람 아이콘 + "이름 <주소>". 주소록은 `recipients.json`(로컬)에만 있고 서버 권한을 더 묻지 않는다.
Note: 처음 계획은 Graph `/me/people`이었으나 People.Read 권한이 새로 필요하고, 사용자 동의를 막은 조직에서는 로그인이 실패할 수 있어 로컬 주소록으로 바꿨다.
Status: doing (코드 완료, 맥 빌드·직접 입력 대기)

### S-019 키보드로 목록 이동
As the user, 위/아래 화살표로 메일을 옮겨 가며 읽고, Space로 본문을 내린다.
Screens: inbox
Depends: S-004
Acceptance:
- [manual] 목록에 초점이 있을 때 ↑↓로 메일을 옮기면 본문이 바로 바뀐다 (List 기본 동작).
- [manual] Space는 본문을 한 쪽 내리고, 본문 끝이면 다음 메일을 연다. ⇧Space는 반대로 올라가고, 처음이면 이전 메일.
- [self] 다음/이전 메일로 옮기고, 목록 끝에서는 그대로 있는다.
UX: 맥 Mail과 같은 키. 메뉴 단축키로 쓰지 않는다(글자 입력 중에도 불리므로). 목록의 onKeyPress로만.
Status: doing (코드 완료, 맥 빌드·직접 키 입력 대기)

## M4 Polish

### S-020 앱 아이콘
As the user, Dock에서 보라 배경에 봉투와 클립이 있는 Liquid Glass 아이콘을 본다 (`app-icon` skill).
Acceptance:
- [manual] `tools/make_icon.sh`가 성공하고, `tools/icon_review.sh`의 기본·다크·틴트·클리어와 16pt에서 클립과 봉투가 보인다.
- [manual] Dock에서 Apple Mail(파란 배경 흰 봉투)과 구분된다.
Status: doing (레이어와 icon.json 완료, 맥에서 actool 컴파일과 검토 대기. 미리보기: docs/design/icon-preview.png)

### S-021 계정별 서명 규칙 화면
As the user, 설정 > 서명에서 계정마다 다른 기본 서명을 정한다 (모델 `SignatureRules.perAccount`는 있음).
Status: todo

### S-022 초안 저장
As the user, 작성 창을 닫을 때 "초안으로 저장"을 골라 임시 보관함에 남긴다.
Status: todo

## Later
- 대화(스레드) 보기, 오프라인 캐시, 새 메일 알림
- Sparkle 업데이트와 공증 배포 (기획안 7장)
- 4MB를 넘는 메일: Graph 업로드 세션으로 큰 첨부 보내기

## Dropped
- 여러 계정 동시 사용: 브리프에서 버전 1은 계정 1개.
- SMTP 릴레이: Graph에 MIME을 그대로 보내므로 필요 없음.
- 분석, 온보딩 투어, 결제: 개인 앱에 필요 없음.
