# ExchangeMail stories

Status 규칙: `todo`, `doing`, `done`, `dropped`.
이 저장소의 첫 코드는 Swift 컴파일러가 없는 Linux 컨테이너에서 작성되었다.
2026-11-01: 맥에서 빌드, `swift test`, `tools/selftest.sh`가 모두 통과하고 사용자가 기능을 확인해 M1~M4가 done이 되었다.

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
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-002 사이드바에서 폴더 고르기
As the user, 사이드바에서 폴더를 눌러 그 폴더의 메일 목록을 본다.
Screens: inbox, sentitems
Depends: S-001
Acceptance:
- [snap] 받은 편지함, 임시 보관함, 보낸 편지함, 보관, 정크 메일, 지운 편지함 순서이고, 각자 맞는 SF Symbol이 있다.
- [snap] 안 읽은 메일이 있는 폴더에 숫자 배지가 있다.
- [unit] 폴더 정렬은 영어·한국어 표시 이름 모두에서 같은 순서다.
- [self] 시작하면 받은 편지함이 선택된다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-003 메일 목록 훑어보기
As the user, 목록에서 보낸 사람, 제목, 날짜, 미리보기, 첨부 표시, 안 읽음 점을 본다.
Screens: inbox
Depends: S-002
Acceptance:
- [snap] 안 읽은 메일은 파란 점과 굵은 보낸 사람 이름으로 보인다.
- [snap] 오늘 받은 메일은 시각, 그 전 메일은 날짜를 보인다.
- [self] 50개를 넘는 폴더에서 목록 끝에 닿으면 다음 쪽을 더 불러온다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

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
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-005 첨부파일 저장
As the user, 받은 메일의 첨부 칩을 눌러 파일로 저장한다.
Screens: inbox
Depends: S-004
Acceptance:
- [unit] 저장 이름은 NFC로 정규화되고 `/`, `\`, 제어 문자가 빠진다.
- [manual] 저장 패널이 열리고, 고른 위치에 원본과 같은 바이트가 쓰인다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

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
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

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
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-008 메일마다 첨부 보정 끄고 켜기
As the user, 작성 창의 "첨부 보정" 체크로 이번 메일에만 보정을 끄거나 켜고, 첨부가 어떤 이름으로 나갈지 본다.
Screens: compose
Depends: S-006
Acceptance:
- [snap] 첨부 칩은 보정 후 나갈 이름(NFC)을 보이고, 본문 이미지를 첨부로 뺄 때는 "본문 이미지 n개가 첨부로 나갑니다"라는 안내가 보인다.
- [unit] 보정을 끄면 본문 이미지는 인라인으로 남고 EUC-KR은 쓰지 않는다. 파일명 NFC와 RFC 2231은 항상 적용된다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-009 서명 여러 개 만들기
As the user, 설정 > 서명에서 서명을 추가, 이름 변경, 삭제하고 글꼴, 크기, 색, 정렬, 링크, 이미지로 꾸미거나 HTML 소스를 직접 고친다.
Screens: settings-signatures
Acceptance:
- [snap] 왼쪽은 서명 목록과 +/− 버튼, 오른쪽은 이름 칸, 서식 막대, 편집기다.
- [self] 서명을 추가하면 목록 끝에 선택된 채 생기고, 지우면 그 서명을 쓰던 기본 규칙도 지워진다.
- [self] 서명은 앱을 다시 열어도 남는다 (`signatures.json`).
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-010 상황별 기본 서명과 작성 중 전환
As the user, 새 메일, 답장, 전달마다 기본 서명을 정하고, 작성 창에서 서명 메뉴로 언제든 바꾼다.
Screens: settings-signatures, compose
Depends: S-009, S-006
Acceptance:
- [unit] 계정 규칙이 전역 규칙보다 앞서고, "없음"을 고른 규칙은 서명을 넣지 않는다.
- [unit] 서명을 바꾸면 본문의 서명 블록 한 개만 바뀌고 인용문 앞자리를 지킨다.
- [snap] 작성 창이 열리면 기본 서명이 본문 빈 줄 아래, 인용문 위에 들어가 있다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

## M2 Organize: 정리와 찾기

### S-011 보관하기
As the user, ⌃⌘A나 툴바 버튼으로 고른 메일을 보관 폴더로 옮긴다.
Acceptance:
- [self] 옮긴 메일은 목록에서 사라지고 다음 메일이 선택된다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-012 지우기
As the user, 목록에서 Delete를 누르거나 툴바 휴지통으로 메일을 지운 편지함으로 옮긴다.
Acceptance:
- [self] 옮긴 메일은 목록에서 사라지고 다음 메일이 선택된다.
- [manual] ⌘Z로 되돌리면 원래 폴더로 돌아온다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-013 읽음/안 읽음 표시
As the user, ⇧⌘U나 컨텍스트 메뉴로 읽음 상태를 바꾼다.
Acceptance:
- [self] 목록의 점과 폴더 배지 숫자가 같이 바뀐다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-014 메일 검색
As the user, 툴바 검색 칸에 단어를 넣고 Return으로 현재 폴더를 검색한다.
Acceptance:
- [unit] 검색 요청은 `$search`와 `ConsistencyLevel: eventual`을 쓰고 `$orderby`는 쓰지 않는다.
- [self] 검색어를 지우면 원래 목록이 돌아온다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-015 받은 메일 가져오기
As the user, ⇧⌘N이나 새로고침 버튼으로 폴더와 목록을 다시 불러온다. 앱이 앞에 있으면 2분마다 저절로 가져온다.
Acceptance:
- [self] 새로고침 뒤에도 선택한 폴더와 메일이 유지된다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-016 원격 이미지 불러오기
As the user, 차단 막대의 "불러오기"나 보기 메뉴로 이 메일의 원격 이미지를 불러온다.
Depends: S-004
Acceptance:
- [unit] 허용한 메일은 원격 `img-src`를 허용하는 정책으로 다시 그린다.
- [manual] 다른 메일로 옮기면 다시 차단된다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

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
Status: done (맥에서 사용자가 확인, 2026-11-01)

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
Status: done (맥에서 사용자가 확인, 2026-11-01)

### S-019 키보드로 목록 이동
As the user, 위/아래 화살표로 메일을 옮겨 가며 읽고, Space로 본문을 내린다.
Screens: inbox
Depends: S-004
Acceptance:
- [manual] 목록에 초점이 있을 때 ↑↓로 메일을 옮기면 본문이 바로 바뀐다 (List 기본 동작).
- [manual] Space는 본문을 한 쪽 내리고, 본문 끝이면 다음 메일을 연다. ⇧Space는 반대로 올라가고, 처음이면 이전 메일.
- [self] 다음/이전 메일로 옮기고, 목록 끝에서는 그대로 있는다.
UX: 맥 Mail과 같은 키. 메뉴 단축키로 쓰지 않는다(글자 입력 중에도 불리므로). 목록의 onKeyPress로만.
Status: done (맥에서 사용자가 확인, 2026-11-01)

## M4 Polish

### S-020 앱 아이콘
As the user, Dock에서 보라 배경에 봉투와 클립이 있는 Liquid Glass 아이콘을 본다 (`app-icon` skill).
Acceptance:
- [manual] `tools/make_icon.sh`가 성공하고, `tools/icon_review.sh`의 기본·다크·틴트·클리어와 16pt에서 클립과 봉투가 보인다.
- [manual] Dock에서 Apple Mail(파란 배경 흰 봉투)과 구분된다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-021 계정별 서명 규칙 화면
As the user, 설정 > 서명의 "기본 서명"에서 "이 계정"을 골라, 로그인한 계정에서만 쓸 기본 서명을 정한다.
Screens: settings-signatures
Depends: S-010
Acceptance:
- [snap] 로그인했으면 "모든 계정 / 이 계정" 선택이 보이고, "이 계정"에는 "모든 계정 설정 따르기"가 있다.
- [unit] 계정 규칙이 앞서고, "따르기"를 고르면 계정 규칙이 지워져 모든 계정 규칙으로 돌아간다.
- [self] 계정에서 "없음"을 고르면 그 종류의 메일에 서명을 넣지 않는다.
UX: 범위는 분할 컨트롤. 아래 설명 줄이 지금 어느 범위를 고치는지 말한다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-022 초안 저장
As the user, 쓰던 메일이 임시 보관함에 저장되고(⌘S, 30초마다, 창을 닫을 때), 나중에 그 초안을 이어서 쓴다.
Screens: compose, drafts
Depends: S-006
Acceptance:
- [self] 아무것도 안 쓴 새 창은 닫아도 초안을 남기지 않는다.
- [self] 받는 사람이 비었거나 틀려도 초안으로 저장되고, 다시 저장하면 초안이 늘지 않고 바뀐다.
- [self] 임시 보관함에서 초안을 고르고 "이어서 쓰기"(⌘O, Return)를 누르면 받는 사람·제목·본문·첨부가 그대로 열린다.
- [self] 이어 쓴 초안을 보내면 임시 보관함에서 지워진다. "삭제"를 누르면 저장된 초안도 지워진다.
- [snap] 작성 창 제목 아래에 "초안 저장됨 오후 3:12"가 보인다.
- [manual] 실제 계정에서 저장한 초안이 Outlook 웹의 임시 보관함에도 보인다.
UX: 맥 Mail처럼 묻지 않고 저장한다(닫을 때 잃어버리지 않게). 초안은 보정 없이 저장하고 보낼 때 보정한다.
Note: Exchange가 저장하며 HTML의 `data-signature` 속성을 지우면, 다시 연 초안의 서명 그림이 보낼 때 일반 첨부로 나갈 수 있다. 실제 계정에서 확인 필요.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

## M5 Large mail

### S-023 4MB가 넘는 메일 보내기
As the user, 큰 파일(예: 20MB PDF)을 첨부해 보내면, 큰 첨부는 따로 올라가고 진행률이 보인 뒤 메일이 나간다.
Screens: compose
Depends: S-006
Acceptance:
- [unit] 요청이 4MB를 넘으면 가장 큰 첨부부터 업로드로 옮겨, 남은 MIME가 4MB 안에 들게 한다. 작은 첨부와 서명 그림은 MIME에 남는다.
- [unit] 업로드 조각은 320 KiB의 배수이고 `Content-Range: bytes a-b/total`이 끝까지 이어진다.
- [unit] 첨부 하나가 150MB를 넘거나, 본문 안 그림만으로 4MB를 넘으면 보내기 전에 이유를 알린다.
- [self] 데모 모드에서 5MB 첨부를 보내면 업로드 1개, 초안 → 보냄 순서로 처리되고 임시 보관함에 남지 않는다.
- [self] 큰 첨부가 있는 메일도 초안으로 저장된다.
- [manual] 실제 계정에서 20MB PDF를 보내 Outlook에서 파일명이 한글로 보인다.
UX: 보내는 동안 창 제목 아래 "큰 첨부 올리는 중 1/2 · 45%"와 첨부 막대의 진행 막대. 큰 첨부가 있으면 첨부 막대에 "큰 첨부는 따로 올려 보냅니다" 안내.
Note: 업로드한 첨부는 Exchange가 파일명을 기록한다 (NFC는 적용, EUC-KR 옵션은 적용 안 됨). 조직의 메일 크기 한도(기본 35MB)를 넘으면 서버 오류를 그대로 알린다.
Status: done (맥에서 빌드·swift test·selftest 통과, 실제 계정 발송 확인 2026-11-01)

## M6 Notifications

### S-024 새 메일 알림과 Dock 배지
As the user, 앱이 뒤에 있어도 새 메일이 오면 알림을 받고, 알림을 누르면 그 메일이 열리며, Dock에서 읽지 않은 메일 수를 본다.
Screens: settings-notifications
Depends: S-002, S-004
Acceptance:
- [unit] 지난 확인 이후 도착한 읽지 않은 메일만 새 메일이다. 처음 확인은 기준 시각만 정하고 알리지 않는다. 이미 알린 메일은 다시 알리지 않는다.
- [unit] 새 메일이 3통 이하면 한 통씩(보낸 사람, 제목, 미리보기), 4통 이상이면 "새 메일 n통" 하나로 알린다.
- [self] 데모 받은 편지함에 메일이 오면 알림 1건이 기록되고, 다시 확인해도 늘지 않는다.
- [self] Dock 배지는 받은 편지함의 읽지 않은 수이고, 0이면 사라진다. 설정에서 끄면 사라진다.
- [self] 알림을 누른 것처럼 열면 받은 편지함의 그 메일이 선택된다.
- [manual] 앱이 뒤에 있을 때 배너가 뜨고, 앞에 있을 때는 배너 없이 알림 센터에만 남는다.
- [snap] 설정 > 알림 탭에 새 메일 알림, 소리, Dock 배지 토글이 있다.
UX: 알림 권한은 알림을 처음 켤 때(기본은 켜짐이므로 첫 로그인 뒤) 묻는다. 거절하면 설정 탭에 "시스템 설정에서 허용" 버튼.
Note: 받은 편지함만 알린다. 앱이 꺼져 있으면 알리지 않는다(서버 푸시 없음). 뒤에 있을 때는 macOS가 타이머를 늦출 수 있어 몇 분 늦을 수 있다.
Status: done (맥에서 빌드·swift test·selftest 통과, 실제 알림·배지 확인 2026-11-01)

## M7 Conversations

### S-025 대화별로 묶어 보기
As the user, 같은 대화의 메일을 목록에서 한 줄로 보고, 대화를 열면 주고받은 메일(보낸 답장 포함)을 차례로 훑으며 한 통씩 펼쳐 읽는다.
Screens: inbox
Depends: S-003, S-004
Acceptance:
- [unit] 같은 conversationId의 메일은 한 줄로 묶이고, 줄은 최근 메일 순이며, 메일 수·안 읽음·첨부·참여자(최근 보낸 사람부터, 중복 없이)를 갖는다. conversationId가 없으면 혼자 한 줄이다.
- [unit] 대화 요청은 `$filter=conversationId eq '...'`이고, 작은따옴표는 두 번 쓰며, `+`는 %2B로 보낸다.
- [self] 데모 받은 편지함의 견적 대화는 한 줄(메일 2통)이고, 열면 보낸 편지함의 내 메일까지 3통이 오래된 순으로 보인다.
- [self] 대화 안의 다른 메일을 누르면 그 메일 본문이 열리고, 답장은 그 메일에 대한 답장이 된다.
- [self] 대화를 열면 이 폴더의 그 대화 안 읽은 메일이 모두 읽음이 된다. 보관하면 이 폴더의 그 대화가 모두 옮겨진다.
- [self] 보기 > 대화별로 정리(⌃⌘T)를 끄면 예전처럼 한 통씩 보인다.
- [snap] 대화 줄에 메일 수 배지가 있고, 본문 위에 대화 목록이 접힌 줄로 보인다.
UX: 대화 줄의 참여자는 "김민지, 나". 펼친 메일 줄은 강조색 막대로 표시. 다른 폴더의 메일에는 폴더 이름 꼬리표(예: "보낸 편지함").
Status: done (맥에서 빌드·selftest 통과, 실제 계정에서 대화 보기·보관 되돌리기·⌃⌘T 확인 2026-11-01)

## M8 Offline

### S-026 오프라인에서 최근 메일 읽기
As the user, 네트워크가 없어도 최근에 본 폴더 목록과 메일 본문을 읽고, 앱을 열면 저장된 목록이 바로 보인다.
Screens: inbox
Depends: S-002, S-003, S-004
Acceptance:
- [unit] 폴더, 폴더별 목록, 메일 본문, 첨부가 계정별 폴더에 저장되고 다시 읽힌다. 2MB가 넘는 일반 첨부는 내용 없이 이름만 남긴다.
- [unit] 본문은 최근 500통만 남기고, 지우기·로그아웃하면 그 계정의 캐시가 모두 사라진다.
- [unit] 연결 끊김·시간 초과·호스트 없음은 "오프라인"으로, 그 밖의 오류는 그대로 다룬다.
- [self] 오프라인이 되면 저장된 받은 편지함과 열어 본 메일 본문이 그대로 보이고, 오프라인 표시가 켜진다.
- [self] 오프라인에서 보관이나 보내기는 하지 않고 이유를 알린다. 다시 연결되면 오프라인 표시가 꺼진다.
- [snap] 오프라인일 때 목록 위에 "오프라인 · 저장된 메일" 막대와 "다시 연결" 버튼이 보인다.
- [manual] 앱을 다시 열면 서버 응답 전에 저장된 목록이 먼저 보인다.
UX: 오프라인 막대는 경고가 아닌 안내(회색). 읽음 표시처럼 자동으로 일어나는 일은 오프라인이면 조용히 넘긴다.
Note: 메일 내용이 Mac에 저장된다. 설정 > 계정에서 끄거나 지울 수 있고, 로그아웃하면 지운다.
Status: done (맥에서 빌드·swift test·selftest 통과, Wi-Fi를 끄고 실제 계정으로 확인 2026-11-01)

## M9 Organize more

### S-027 여러 통 골라 한꺼번에 처리하기
As the user, 목록에서 ⌘·⇧ 클릭으로 여러 통(또는 대화)을 골라 보관, 지우기, 이동, 읽음, 깃발을 한 번에 한다.
Acceptance:
- [self] 여러 통을 고르면 본문 자리에 "메시지 n개 선택됨"이 보이고, 보관하면 고른 메일이 모두 옮겨지며 ⌘Z로 모두 돌아온다.
- [self] 여러 통을 읽음으로 바꾸면 모두 바뀐다(하나라도 안 읽었으면 모두 읽음, 아니면 모두 안 읽음).
- [manual] 오른쪽 클릭 메뉴는 고른 메일 전체에 적용된다. 답장·전달은 한 통만 골랐을 때만 켜진다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-028 다른 폴더로 옮기기
As the user, 메일을 사이드바 폴더로 끌어다 놓거나, 메시지 > 이동…(⇧⌘M)이나 오른쪽 클릭 > 이동에서 폴더를 골라 옮긴다.
Depends: S-027
Acceptance:
- [self] 옮긴 메일은 목록에서 사라지고 그 폴더에 나타나며, ⌘Z로 원래 폴더로 돌아온다.
- [manual] 여러 통을 골라 끌면 모두 옮겨진다. 지금 폴더로는 옮길 수 없다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-029 깃발 표시
As the user, ⇧⌘L로 메일에 깃발을 달고 떼며, 사이드바의 "깃발 표시"에서 깃발 단 메일만 모아 본다.
Acceptance:
- [unit] 깃발 요청은 `flag.flagStatus`를 `flagged` / `notFlagged`로 보낸다. 깃발 모아 보기는 모든 폴더에서 `flagStatus eq 'flagged'`로 찾는다.
- [self] 깃발을 달면 목록 줄에 깃발이 보이고 "깃발 표시"에 나타난다. 떼면 사라진다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-030 정크 메일로 표시
As the user, ⇧⌘J로 메일을 정크 메일 폴더로 옮기고, 정크 메일 폴더에서는 같은 명령("정크 아님")으로 받은 편지함에 돌려놓는다.
Acceptance:
- [self] 정크로 표시하면 정크 메일 폴더로, 정크 아님은 받은 편지함으로 옮겨지고 ⌘Z로 되돌린다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

### S-031 폴더 만들기, 이름 바꾸기, 지우기
As the user, 사이드바에서 하위 폴더까지 들여 써서 보고, 폴더를 만들고(사서함 > 새 폴더… ⌃⌘N, 오른쪽 클릭), 이름을 바꾸고, 지운다.
Acceptance:
- [unit] 하위 폴더는 부모 바로 아래에 깊이만큼 들여 써서 놓인다. 잘 알려진 폴더가 맨 위다.
- [self] 새 폴더를 만들면 사이드바에 생기고 골라지며, 이름을 바꾸면 바뀌고, 지우면 사라진다.
- [manual] 받은 편지함 같은 기본 폴더는 이름 바꾸기·지우기가 꺼져 있다. 지우기 전에 확인을 묻는다.
Status: done (맥에서 빌드·swift test·selftest 통과, 사용자 확인 2026-11-01)

## M10 Read more

### S-032 첨부 미리보기
As the user, 첨부 칩을 고르고 Space를 누르거나 "훑어보기"로 Quick Look 미리보기를 연다.
Acceptance:
- [self] 첨부를 NFC 이름의 임시 파일로 써서 Quick Look으로 연다. 내용이 없으면(오프라인의 큰 첨부 등) 이유를 알린다.
- [manual] 칩을 누르면 미리보기, 오른쪽 클릭에 "훑어보기 / 저장…", 메시지 > 첨부 훑어보기(⌘Y)는 첫 첨부.
Status: done (맥에서 확인, 인쇄 머리글 포함 2026-11-02)

### S-033 모든 폴더에서 검색
As the user, 검색 칸 아래에서 "모든 폴더 / 이 폴더"를 골라 사서함 전체를 찾는다.
Acceptance:
- [unit] 모든 폴더 검색은 `/me/messages`에 `$search`를 쓰고 `$orderby`는 쓰지 않는다.
- [self] "모든 폴더"면 보낸 편지함 메일도 나오고 폴더 꼬리표가 붙는다. "이 폴더"로 바꾸면 다시 찾는다.
Status: done (맥에서 확인, 인쇄 머리글 포함 2026-11-02)

### S-034 인쇄
As the user, ⌘P로 지금 보는 메일(머리글 포함)을 인쇄하거나 PDF로 저장한다.
Acceptance:
- [unit] 인쇄 문서는 CSP를 맨 앞에, 이스케이프한 머리글(제목, 보낸 사람, 받는 사람, 참조, 날짜)을 본문 앞에 둔다.
- [unit] 머리글은 본문 문서의 `<body>` 바로 안쪽에 들어가고, 평문 메일도 머리글이 붙는다.
- [manual] 본문을 클릭해 둔 채 ⌘P를 눌러도 머리글이 붙는다.
- [manual] 파일 > 인쇄…(⌘P)로 인쇄 창이 열리고, PDF로 저장하면 머리글과 한글 본문이 그대로 나온다.
Status: done (맥에서 확인, 인쇄 머리글 포함 2026-11-02)

## M11 Write more

### S-035 받은 첨부를 Finder로 끌어 저장
As the user, 본문 머리글의 첨부 칩을 Finder나 데스크톱으로 끌어 파일로 저장한다.
Acceptance:
- [self] 첨부 칩을 끌면 NFC 이름의 파일을 넘긴다.
- [manual] Finder나 데스크톱에 놓으면 그 자리에 파일이 생긴다.
Status: doing (코드 완료, 맥 빌드·확인 대기)

### S-036 보내기 취소
As the user, 보내기를 누른 뒤 정해 둔 몇 초(설정: 끔·5·10·20초) 안에 "보내기 취소"를 눌러 작성 창으로 돌아온다.
Acceptance:
- [self] 보내기를 누르면 남은 초를 세고, 그 사이 "보내기 취소"(Esc)를 누르면 보내지 않고 창에 남는다. 다 지나면 보낸다.
- [manual] 설정 > 보내기에서 끔·5·10·20초를 고른다 (기본 10초).
Status: doing (코드 완료, 맥 빌드·확인 대기)

### S-037 예약 보내기
As the user, 보내기 버튼의 메뉴에서 "나중에 보내기…"로 날짜와 시각을 골라 Exchange가 그때 보내게 한다.
Acceptance:
- [unit] 지연 발송 속성은 `SystemTime 0x3FEF`에 UTC 시각이다. 프리셋은 오늘 오후 6시(5분 넘게 남았을 때), 내일 오전 9시, 다음 월요일 오전 9시.
- [self] 예약하면 초안 → 시각 붙이기 → 보내기 순서로 처리된다. 1분 안의 시각은 예약하지 않는다.
- [manual] 실제 계정에서 예약한 메일이 그 시각에 받는 사람에게 도착한다.
Status: doing (코드 완료, 맥 빌드·확인 대기)

### S-038 회의 초대에 답하기
As the user, 회의 초대 메일에서 일시·장소를 보고 수락·미정·거절로 답한다 (Calendars.ReadWrite 권한).
Acceptance:
- [unit] `@odata.type`이 eventMessageRequest면 회의 초대이고, 일정 시각은 UTC·IANA 시간대로 읽는다.
- [self] 회의 초대를 열면 일시·장소가 보이고, 수락하면 "수락함"이 보인다.
- [manual] 실제 계정에서 수락하면 Outlook 일정에 들어가고 보낸 사람에게 응답이 간다 (Calendars.ReadWrite 권한).
Status: doing (코드 완료, 맥 빌드·확인 대기)

## M12 Mailbox settings

### S-039 규칙
As the user, 설정 > 규칙에서 "보낸 사람/제목에 ~가 있으면 → 폴더로 이동·읽음·깃발·지우기" 규칙을 만들고 켜고 끄고 지운다 (서버 규칙, MailboxSettings.ReadWrite).
Status: todo

### S-040 부재중 자동 응답
As the user, 설정 > 자동 응답에서 자동 응답을 켜고, 기간과 조직 안·밖에 보낼 글을 정한다.
Status: todo

## Later
- Sparkle 업데이트와 공증 배포 (기획안 7장)

## Dropped
- 여러 계정 동시 사용: 브리프에서 버전 1은 계정 1개.
- SMTP 릴레이: Graph에 MIME을 그대로 보내므로 필요 없음.
- 분석, 온보딩 투어, 결제: 개인 앱에 필요 없음.
