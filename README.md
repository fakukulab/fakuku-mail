# FAKUKU Mail — Exchange 연동 맥용 메일 클라이언트

코드 이름은 `ExchangeMail`입니다(폴더, Swift 모듈, 실행 파일, 데이터 폴더). 화면과 Dock에 보이는 이름은 **FAKUKU Mail**입니다.

맥 Mail과 비슷한 3단 레이아웃(폴더 / 목록 / 본문)의 SwiftUI 앱입니다.
[BAMA](https://github.com/daveebbelaar/bama) 템플릿(Swift Package, macOS 26, Swift 6.2)으로 다시 만들었고,
처음 받은 코드(`docs/original/README.md`)의 기능을 모두 옮긴 뒤 버그를 고치고 기능을 더했습니다.

- **Microsoft Exchange Online** 연동: Microsoft Graph API + OAuth2(PKCE), 토큰은 Keychain
- **첨부 보정** (기획안 F1~F3, F5, F6, F9, F10)
  - 본문에 넣은 그림 → 일반 첨부로 발송 (서명·인용문 안 그림은 인라인 유지)
  - 첨부 파일명 NFC 정규화, RFC 2047(Base64) + RFC 2231 동시 기록 (긴 이름은 RFC 2231 연속 파라미터), EUC-KR 옵션
  - Graph로 MIME을 그대로 보내므로 SMTP 릴레이 불필요
  - 작성 창에서 메일마다 끄고 켜기, 몇 개의 그림이 첨부로 나가는지 미리 표시
- **서명 여러 개**: 추가/삭제, 새 메일·답장·전달별 기본 서명, 작성 창에서 전환, 리치 편집기와 HTML 소스 편집
- **읽기**: 인라인(cid) 그림 표시, 원격 이미지 차단과 "불러오기", 링크는 기본 브라우저로, 첨부 저장
- **정리**: 보관, 지우기(⌘Z로 되돌리기), 읽음/안 읽음, 검색, 목록 더 불러오기, 2분마다 받은 메일 가져오기
- **답장 스레드**: `In-Reply-To`, `References` 헤더 (Outlook·Gmail에서 대화로 묶임), 전달 시 원본 첨부 포함

## 빌드 (Mac에서)

필요: macOS 26 이상, Xcode 26(또는 Swift 6.2 Command Line Tools). XcodeGen은 필요 없습니다.

```bash
./build.sh --open
```

`~/Applications/FAKUKU Mail.app`이 설치되고 열립니다. 예전 `ExchangeMail.app`은 지워집니다. 확인 단계:

```bash
swift test --scratch-path ~/Library/Developer/ExchangeMail/test-build   # 단위 테스트 (ExchangeMailKit)
```

```bash
tools/selftest.sh    # 데모 사서함에서 앱 함수를 돌려 PASS/FAIL 출력, 모두 통과하면 종료 코드 0
```

```bash
tools/snap.sh        # 모든 화면을 밝은/어두운 모드로 /tmp/ExchangeMail-shots/에 저장
```

```bash
tools/demo.sh        # 로그인 없이 예시 메일로 앱 둘러보기
```

> **검증 상태**: 이 코드는 Swift 컴파일러가 없는 Linux 환경에서 작성되었습니다. 문법 검사(tree-sitter)와 그리드 검사는 통과했지만
> **아직 컴파일·실행하지 않았습니다.** 첫 빌드에서 사소한 컴파일 오류가 나올 수 있습니다. Claude Code에서 이 폴더를 열고
> "`./build.sh` 오류를 고쳐 줘"라고 하면 BAMA `build-and-verify` 스킬로 이어서 고칠 수 있습니다.

## 번들 ID 바꾸기

번들 ID는 `com.fakukulab.fakukumail`입니다. 다시 바꾸려면 다음 두 곳을 같이 고치세요. Azure 리디렉션 URI와 Keychain 항목 이름이 이 값을 씁니다.

- `Info.plist.in`의 `CFBundleIdentifier`
- `tools/snap.sh`, `tools/selftest.sh`의 `savedState` 경로

## Azure 앱 등록 (1회)

1. portal.azure.com → Microsoft Entra ID → 앱 등록 → 새 등록
2. 지원 계정 유형: 조직 디렉터리(+개인 계정 필요 시 포함)
3. 플랫폼 추가 → **모바일 및 데스크톱 애플리케이션** → 사용자 지정 리디렉션 URI: `msauth.<번들ID>://auth`
   (기본값이면 `msauth.com.fakukulab.fakukumail://auth`. 앱의 로그인 화면과 설정 > 계정에도 표시됩니다)
4. API 사용 권한(위임): `User.Read`, `Mail.ReadWrite`, `Mail.Send`, `offline_access` (조직 정책에 따라 관리자 동의 필요)
5. 앱 실행 → 로그인 화면에 **애플리케이션(클라이언트) ID** 입력 → "Microsoft로 로그인"

## 구조

```
Sources/ExchangeMailKit     순수 로직(테스트 가능): FilenameEncoder, HTMLProcessor, MIMEBuilder, Signature,
                            Addresses, ComposeDraft(답장·전달), MailContent(cid·원격 이미지·CSP), MailModels, OAuth
Sources/ExchangeMail        앱
  App.swift                 창, 메뉴(⌘N, ⌘R, ⇧⌘R, ⇧⌘F, ⌃⌘A, ⇧⌘U, ⇧⌘N), 저장 위치
  AppModel.swift            폴더·목록·본문 상태와 동작
  Auth/                     GraphAuth(PKCE), Keychain
  Mail/                     MailService 프로토콜, GraphMailService, DemoMailService(예시 사서함)
  Compose/                  작성 창, 리치 텍스트 편집기, ComposeSender(입력 → 보정된 MIME)
  Views/                    목록, 본문, 로그인, 설정 > 서명
  SettingsView.swift        설정: 계정, 서명, 첨부 보정, 모양
  Snapshot.swift, SelfTest.swift   BAMA 검증 도구
Tests/ExchangeMailKitTests  Swift Testing 단위 테스트
docs/                       BRIEF.md, STORIES.md(백로그), GLOSSARY.md, original/(처음 받은 README)
```

## 처음 코드에서 고친 점

- **한글 파일명이 퍼센트 인코딩되지 않던 문제**: `CharacterSet.alphanumerics`는 한글을 포함하므로 `filename*=`에 한글이 그대로 들어갔습니다. ASCII attr-char만 허용하도록 고쳤습니다.
- **본문 그림 위치 계산 오류**: NSRange(UTF-16) 위치를 `Character` 위치로 써서, 앞에 NFD 한글·이모지가 있으면 서명 판정이 틀리거나 멈출 수 있었습니다.
- **EUC-KR로 쓸 수 없는 글자가 조용히 빠지던 문제**: 그런 이름은 UTF-8로 되돌아갑니다.
- **답장이 스레드로 묶이지 않던 문제**: `In-Reply-To`가 MIME에 들어가지 않았고, 들어가도 Graph id였습니다. internetMessageId와 References를 씁니다.
- **인용문의 그림**: 답장 인용문의 cid 그림이 깨지거나, 보정 시 첨부로 빠지던 문제를 고쳤습니다(인용문은 인라인 유지).
- **토큰 갱신 경쟁**: 여러 요청이 동시에 갱신하지 않도록 한 번만 갱신하고, 만료되면 로그인 화면으로 돌아갑니다.
- **받은 메일 보안**: 원격 이미지 기본 차단(CSP), meta refresh 등 링크 클릭이 아닌 이동 차단, 링크는 브라우저로.
- **4MB 제한**: Graph 요청 한도를 넘는 메일은 보내기 전에 알려 줍니다.

## 알려진 제한 / 다음 단계

`docs/STORIES.md`의 M3, M4와 `Later`를 보세요. 첨부 끌어다 놓기, 받는 사람 자동완성, 키보드 목록 이동, 앱 아이콘, 계정별 서명 규칙 화면, 초안 저장, 여러 계정, 스레드 보기, 오프라인 캐시, 알림, 4MB 넘는 메일(업로드 세션), Sparkle·공증 배포.
