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

### 4. 자동 업데이트 서명 키 (Sparkle, 1.0.2부터)
- 앱은 하루에 한 번 `https://mail.fakukulab.com/appcast.xml`(저장소의 `site/appcast.xml`)을 보고 새 버전을 받는다.
  받은 DMG는 EdDSA 서명으로 확인한다: 앱 안의 공개 키(`Info.plist.in`의 `SUPublicEDKey`)와 키체인의 비밀 키가 짝이다.
- 비밀 키는 2026-11-07에 이 Mac의 로그인 키체인에 만들었다 (계정 `com.fakukulab.fakukumail`). 확인:
  ```
  ~/Library/Developer/FAKUKUMail/build/artifacts/sparkle/Sparkle/bin/generate_keys -p --account com.fakukulab.fakukumail
  ```
  공개 키 `GQ7AYZ8tJGFCA8kvzElRSwZ28L9/PwIVlBa2VUTmGQY=` 가 나오면 된다.
- **비밀 키를 꼭 따로 보관한다.** 잃어버리면 이미 깔린 앱이 새 업데이트를 받아들이지 않는다 (모두 손으로 다시 받아야 한다).
  ```
  ~/Library/Developer/FAKUKUMail/build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/fakuku-sparkle-key.txt --account com.fakukulab.fakukumail
  ```
  만든 파일을 암호 관리자 등 안전한 곳에 옮기고 데스크탑의 파일은 지운다. 저장소·iCloud 공유 폴더에는 두지 않는다.
  다른 Mac에서는 `generate_keys -f <파일> --account com.fakukulab.fakukumail`로 가져온다.

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
   GitHub 릴리스에 DMG를 올리고 `site/appcast.xml`에 새 버전(빌드 번호, DMG 주소, EdDSA 서명, 릴리스 노트)을 넣는다.
   (GitHub 웹에서 손으로 올리면 appcast가 생기지 않아 자동 업데이트가 되지 않는다.)
7. `site/appcast.xml`을 커밋해 main에 올린다. GitHub Pages가 내보내면(1~2분) 이미 깔린 앱이 하루 안에 새 버전을 알린다.
   바로 확인: 이전 버전 앱에서 FAKUKU Mail > 업데이트 확인….

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
| release: "업데이트 서명을 못 했습니다" | 키체인에 Sparkle 비밀 키가 없다 (4단계, 백업 파일에서 `generate_keys -f`) |
| 업데이트 창: "업데이트를 확인할 수 없습니다"·서명 오류 | appcast의 서명이 DMG와 다르다 (DMG를 다시 만들었으면 `--publish`로 appcast도 다시) |
| Microsoft 로그인 후 앱으로 안 돌아옴 | 번들 id(`com.fakukulab.fakukumail`)를 바꾸지 않았는지 (Azure 리디렉션 URI가 이것에 묶여 있다) |
