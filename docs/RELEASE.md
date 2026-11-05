# 배포하기 (Developer ID, 공증, DMG)

FAKUKU Mail은 Mac App Store 밖에서 배포한다: Developer ID로 서명하고 Apple 공증을 받은 DMG를
GitHub 릴리스에 올린다. 소개 사이트(mail.fakukulab.com, fakukulab.com)의 다운로드 단추는
`https://github.com/fakukulab/fakuku-mail/releases/latest`를 가리킨다.

## 처음 한 번 준비

### 1. Developer ID Application 인증서
- Apple Developer 계정(팀 `8S2Y83DCGM`)의 **Account Holder**만 만들 수 있다.
- Xcode > 설정 > Accounts > 팀 > **Manage Certificates…** > 왼쪽 아래 **+** > **Developer ID Application**.
- 확인: 터미널에서
  ```
  security find-identity -v -p codesigning | grep "Developer ID Application"
  ```
  한 줄이 나오면 된다.

### 2. 공증(notarytool) 프로필
- account.apple.com > 로그인 및 보안 > **앱 암호**에서 앱 암호를 하나 만든다 (이름 예: notarytool).
- 키체인에 저장 (프로필 이름 `fakuku-notary`):
  ```
  xcrun notarytool store-credentials fakuku-notary --apple-id <Apple 계정 이메일> --team-id 8S2Y83DCGM --password <앱 암호>
  ```

### 3. GitHub CLI (릴리스 올리기)
- `brew install gh` 후 `gh auth login`.

## 배포할 때마다

1. `VERSION` 파일의 번호를 올린다 (예: 1.0.0 → 1.0.1). 앱 정보(설정·FAKUKU Mail에 관하여)에 이 번호가 보인다.
2. 릴리스 노트를 `docs/release-notes/<버전>.md`에 쓴다 (없으면 GitHub가 커밋으로 만든다).
3. 셀프 테스트: `tools/selftest.sh` → `SELFTEST PASS`.
4. 서명·공증·DMG:
   ```
   tools/release.sh
   ```
   `dist/FAKUKU-Mail-<버전>.dmg`가 생긴다 (작업은 `~/Library/Developer/FAKUKUMail/release`에서 한다). 공증은 보통 2~10분.
5. 다른 Mac(또는 새 사용자 계정)에서 DMG를 받아 열어 본다: 경고 없이 열려야 한다.
6. 올리기:
   ```
   tools/release.sh --publish
   ```
   또는 GitHub 웹 > Releases > Draft a new release 에 `dist/`의 DMG와 `.sha256`을 올린다.

## 확인하는 것
- `codesign --verify --strict` : 서명이 온전한가
- `spctl --assess` : Gatekeeper가 "Notarized Developer ID"로 받아들이는가
- 권한(`Config/FAKUKUMail.entitlements`): 맥 캘린더, 연락처. 강화된 런타임에서는 여기 없으면 묻는 창이 뜨지 않는다.

## 막히면
| 증상 | 원인 |
|---|---|
| "Developer ID Application 인증서가 없습니다" | 1단계. Account Holder만 만들 수 있다 |
| notarytool: `Invalid` | `xcrun notarytool log <id> --keychain-profile fakuku-notary`로 이유를 본다 (서명 빠진 파일, 타임스탬프 없음 등) |
| 받은 사람이 "확인되지 않은 개발자" | 공증 전 DMG를 올렸거나 staple이 빠졌다 |
| 캘린더·연락처 권한 창이 안 뜸 | entitlements 없이 서명했다 (`tools/release.sh`로 서명) |
| codesign: "resource fork, Finder information, or similar detritus not allowed" | 문서 폴더를 iCloud로 동기화해 Finder 정보가 붙었다. release.sh는 ~/Library/Developer/FAKUKUMail/release에서 서명한다 |
| 앱을 열면 "키체인에서 FAKUKU Mail이 … 사용하려고 합니다" | 로그인 정보를 다른 서명(개발용)의 앱이 만들었다. Mac 로그인 암호 → 항상 허용. build.sh도 Developer ID가 있으면 그것으로 서명해 다시 뜨지 않게 한다 |
| Microsoft 로그인 후 앱으로 안 돌아옴 | 번들 id(`com.fakukulab.fakukumail`)를 바꾸지 않았는지 (Azure 리디렉션 URI가 이것에 묶여 있다) |
