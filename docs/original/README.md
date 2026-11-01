# ExchangeMail (가칭) — Exchange 연동 맥용 메일 클라이언트

맥 Mail과 비슷한 3단 레이아웃(폴더 / 목록 / 본문)의 SwiftUI 앱입니다.

- **Microsoft Exchange Online** 연동: Microsoft Graph API + OAuth2(PKCE), 토큰은 Keychain에 저장
- **첨부도우미 기능 내장** (기획안 F1~F3, F5, F6, F9, F10)
  - 본문에 넣은 이미지 → 일반 첨부파일로 발송 (서명 이미지는 인라인 유지)
  - 첨부 파일명 NFC 정규화, RFC 2047(Base64) + RFC 2231 동시 기록, EUC-KR 옵션
  - 별도 SMTP 릴레이 불필요: Graph로 MIME을 직접 발송하므로 변환 결과가 그대로 나갑니다
  - 작성 창에서 메일마다 보정 on/off
- **서명 여러 개**: 서명 설정에서 추가/삭제, 새 메일·답장·전달별 기본 서명, 작성 창에서 언제든 전환
- **서명 에디터**: 모든 설치 폰트·크기·색·정렬·링크·이미지 삽입, HTML 소스 직접 편집

## 빌드

1. Xcode 15+ 설치, `brew install xcodegen`
2. `project.yml`의 `PRODUCT_BUNDLE_IDENTIFIER`를 본인 값으로 변경
3. 프로젝트 폴더에서 `xcodegen` → `ExchangeMail.xcodeproj` 생성 → Xcode에서 열어 Run
4. 엔진 테스트: `cd Packages/AttachFixCore && swift test`

> 이 코드는 작성 환경에 Swift 컴파일러가 없어 **빌드·실행 검증을 하지 못했습니다.** 처음 빌드 시 사소한 컴파일 오류가 나올 수 있습니다.

## Azure 앱 등록 (1회)

1. portal.azure.com → Microsoft Entra ID → 앱 등록 → 새 등록
2. 지원 계정 유형: 조직 디렉터리(+개인 계정 필요 시 포함)
3. 플랫폼 추가 → **모바일 및 데스크톱 애플리케이션** → 사용자 지정 리디렉션 URI: `msauth.<번들ID>://auth`
   (예: `msauth.com.example.ExchangeMail://auth`)
4. API 사용 권한(위임): `User.Read`, `Mail.ReadWrite`, `Mail.Send`, `offline_access` (조직 정책에 따라 관리자 동의 필요)
5. 앱 실행 → 로그인 화면에 **애플리케이션(클라이언트) ID** 입력 → 로그인

## 구조

```
Packages/AttachFixCore   순수 로직(테스트 가능): FilenameEncoder, HTMLProcessor, MIMEBuilder, Signature
App/Auth                 GraphAuth(PKCE), KeychainStore
App/Graph                GraphClient(폴더·목록·본문·첨부·발송), 모델
App/Stores               AppState, SignatureStore(JSON 저장)
App/Views                Root(3단), Compose, Settings(계정·서명·첨부 보정), RichTextEditor
```

## 알려진 제한 / 다음 단계

- 단일 계정, 폴더 페이징·스레드 보기·초안 저장·원격 이미지 차단 미구현
- 받는 사람 자동완성(주소록), 첨부 드래그앤드롭 미구현
- 서명 계정별 규칙은 모델(`SignatureRules.perAccount`)만 있고 UI는 없음
- 알림·오프라인 캐시 없음. 업데이트(Sparkle)·공증 배포는 기획안 7장 참고
