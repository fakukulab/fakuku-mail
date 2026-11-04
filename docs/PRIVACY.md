# FAKUKU Mail 개인정보 처리방침 

> 웹 게시본: site/privacy.html → https://fakukulab.github.io/fakuku-mail/privacy.html (둘을 함께 고친다)

시행일: 2026년 11월 4일 · 운영: FAKUKU Lab · 문의: https://github.com/fakukulab/fakuku-mail/issues

FAKUKU Mail("앱")은 Microsoft Exchange Online 메일을 macOS에서 읽고 쓰는 앱입니다.

## 1. 앱 제작자가 모으는 정보
**없습니다.** 앱은 제작자의 서버로 메일, 주소, 사용 기록, 분석 정보를 보내지 않습니다. 광고나 분석 도구가 없습니다.

## 2. 앱이 다루는 정보와 저장 위치
- **메일, 일정, 사서함 설정**: 사용자의 Microsoft 365(Exchange Online) 사서함에 있으며, 앱은 Microsoft Graph로 직접 읽고 씁니다.
- **로그인 토큰**: 사용자의 Mac **키체인**에만 저장합니다. 비밀번호는 앱이 받지 않으며 Microsoft 로그인 창에서 입력합니다.
- **이 Mac에만 저장되는 것** (`~/Library/Application Support/FAKUKUMail/`): 서명, VIP·스마트 메일상자, 개별 발송 템플릿과 그룹,
  최근 메일의 오프라인 사본(로그아웃하면 지움), 사용자가 가져온 메일상자(.mbox).
- **맥 캘린더·연락처**: 사용자가 허용한 경우에만, 수락한 회의를 캘린더에 넣고 연락처 카드를 보입니다.

## 3. 요청하는 Microsoft 권한과 이유
| 권한 | 이유 |
|---|---|
| User.Read | 로그인한 사람의 이름과 주소 |
| Mail.ReadWrite | 메일 읽기, 옮기기, 지우기, 초안 |
| Mail.Send | 메일 보내기 |
| Calendars.ReadWrite | 회의 초대에 답하기 |
| MailboxSettings.ReadWrite | 받은 편지함 규칙, 자동 응답 |
| offline_access | 다시 로그인하지 않고 계속 쓰기 |

## 4. 원격 그림
메일 활동 보호가 켜져 있으면 메일 안의 원격 그림은 사용자의 Mac이 쿠키와 리퍼러 없이 직접 받아 보여 줍니다.
제작자의 중계 서버를 거치지 않습니다.

## 5. 지우기
앱에서 로그아웃하면 토큰과 오프라인 사본을 지웁니다. 앱을 지우고 위 폴더를 지우면 이 Mac의 앱 데이터가 모두 없어집니다.
Microsoft 계정의 앱 권한은 https://myapps.microsoft.com 또는 회사 관리자에게서 철회할 수 있습니다.

---

# FAKUKU Mail Privacy Policy (draft)

FAKUKU Mail does not send your mail, contacts, usage, or analytics to the developer. Mail stays in your Microsoft 365 mailbox
and is accessed directly through Microsoft Graph. Sign-in tokens are kept in your Mac’s Keychain; the app never receives your password.
Signatures, VIPs, templates, an offline copy of recent mail (removed when you sign out), and imported mailboxes are stored only on your Mac.
Calendar and Contacts are used only if you allow them. Permissions requested: User.Read, Mail.ReadWrite, Mail.Send,
Calendars.ReadWrite, MailboxSettings.ReadWrite, offline_access — for the purposes listed above.
Contact: https://github.com/fakukulab/fakuku-mail/issues
