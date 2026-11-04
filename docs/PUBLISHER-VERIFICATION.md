# Microsoft 게시자 확인 (Publisher verification)

FAKUKU Mail의 Azure 앱 등록(클라이언트 ID `cd515a48-5168-4c5f-b4ef-1b925e2c3b95`)에
"확인된 게시자" 파란 표시를 붙이는 절차. 확인되지 않은 멀티 테넌트 앱은 많은 회사에서 직원이 직접 동의할 수 없고
IT 관리자의 승인이 필요하다. 확인을 받으면 동의 화면에 회사 이름과 확인 표시가 보이고, 회사 정책이
"확인된 게시자의 앱은 사용자 동의 허용"이면 직원이 바로 쓸 수 있다.

> Microsoft의 메뉴 이름과 조건은 바뀔 수 있다. 진행 전에 Microsoft Learn의
> "Publisher verification" 문서를 한 번 확인한다.

## 0. 준비물

- [ ] **법인(사업자)**: Microsoft 파트너 프로그램은 회사로 가입한다 (개인은 가입할 수 없다).
- [ ] **회사 도메인**: `fakukulab.com`. 그 도메인의 메일 주소(예 `admin@fakukulab.com`)와 DNS를 고칠 수 있어야 한다.
- [ ] **Microsoft Entra ID 테넌트**: 앱이 등록된 곳. 그 테넌트에서 **애플리케이션 관리자** 이상의 역할,
      로그인 계정에 **다중 인증(MFA)**이 켜져 있어야 한다.

## 1. Microsoft AI Cloud Partner Program 가입 (예전 이름: Microsoft Partner Network, MPN)

- [ ] partner.microsoft.com → 가입 (앱이 등록된 **같은 Entra 테넌트의 회사 계정**으로)
- [ ] 회사 정보 입력, 회사 확인(사업자 서류·전화·메일 확인). 며칠 걸릴 수 있다.
- [ ] 가입한 계정은 Partner Center에서 **MPN 관리자** 또는 **계정 관리자** 역할이어야 한다.
- [ ] Partner Center → 계정 설정 → 법적 정보/식별자에서 **Partner ID(MPN ID)** 확인 (숫자 7자리 정도)
- [ ] 확인 상태가 **"확인됨"(Verified)**이 될 때까지 기다린다.

## 2. 앱에 게시자 도메인 정하기

- [ ] portal.azure.com → 앱 등록 → FAKUKU Mail → **브랜딩 및 속성(Branding & properties)**
- [ ] **게시자 도메인(Publisher domain)**을 `fakukulab.com`으로. 방법은 둘 중 하나:
  - (권장) 테넌트에 `fakukulab.com`을 사용자 지정 도메인으로 추가하고 DNS TXT로 확인 (Entra ID → 사용자 지정 도메인 이름), 또는
  - 화면이 주는 `microsoft-identity-association.json` 파일을 `https://<도메인>/.well-known/` 에 올려 확인
- [ ] 조건: 파트너 프로그램 가입 때 확인한 메일 주소의 도메인과 게시자 도메인이 같아야 한다.

## 3. 브랜딩 채우기 (동의 화면에 보인다, 신뢰에 중요)

- [ ] 로고 (Icon/AppIcon.icon을 PNG로: `tools/icon_review.sh`로 만든 그림에서 잘라 쓴다)
- [ ] 홈페이지: https://mail.fakukulab.com/
- [ ] **개인정보 처리방침 URL**: https://mail.fakukulab.com/privacy.html
- [ ] **서비스 약관 URL**: https://mail.fakukulab.com/terms.html
      (site/ 폴더, .github/workflows/pages.yml이 올린다. 처음 한 번 Settings → Pages → Source = GitHub Actions)

## 4. 게시자 확인 실행

- [ ] 같은 **브랜딩 및 속성** 화면 아래 **게시자 확인** → **MPN ID 추가** → Partner ID 입력 → **확인 및 저장**
- [ ] 성공하면 앱 이름 옆에 파란 확인 표시, 동의 화면에 "확인됨"과 회사 이름

## 5. 확인 뒤에도 알아 둘 점

- 회사의 동의 정책이 "확인된 게시자 + 위험도가 낮은 권한만 사용자 동의 허용"이면,
  FAKUKU Mail이 쓰는 `Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `MailboxSettings.ReadWrite`는
  회사가 "위험도 낮음"으로 지정하지 않는 한 **여전히 관리자 승인이 필요할 수 있다**.
  그때는 로그인 화면의 **관리자 승인 링크 복사**로 IT 관리자에게 한 번 승인을 받는다.
- 게시자 도메인이나 앱 이름을 바꾸면 다시 확인이 필요할 수 있다.

## 막히는 곳 (자주)

| 증상 | 원인 |
|---|---|
| "MPN ID가 유효하지 않음" | 파트너 계정 확인이 아직 끝나지 않았거나, 다른 테넌트의 계정으로 가입 |
| "게시자 도메인이 일치하지 않음" | 파트너 가입 메일 도메인 ≠ 앱의 게시자 도메인 |
| 확인 단추가 회색 | 테넌트 역할 부족, 또는 로그인 계정에 MFA가 없음 |
| 개인 Microsoft 계정으로 등록된 앱 | 개인 계정(Outlook.com) 쪽 앱 등록은 게시자 확인이 안 된다. 회사 Entra 테넌트에 다시 등록 |
