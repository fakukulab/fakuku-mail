#!/bin/zsh
# FAKUKU Mail 배포본 만들기: Developer ID 서명(강화된 런타임) → Apple 공증 → DMG → (원하면) GitHub 릴리스.
# 처음 한 번 준비할 것은 docs/RELEASE.md.
#
# Usage: tools/release.sh            dist/FAKUKU-Mail-<버전>.dmg 를 만들고 공증한다
#        tools/release.sh --publish  위 + GitHub 릴리스 v<버전> 에 올린다 (gh 필요)
#        tools/release.sh --no-notarize   서명·DMG만 (공증 계정 없이 시험할 때)
#
# 환경 변수: DEVELOPER_ID   서명 인증서 이름 (없으면 키체인에서 "Developer ID Application" 첫 번째)
#            NOTARY_PROFILE notarytool 키체인 프로필 이름 (기본 fakuku-notary)
set -euo pipefail
here=${0:A:h:h}
publish=false; notarize=true
[[ " $* " == *" --publish "* ]] && publish=true
[[ " $* " == *" --no-notarize "* ]] && notarize=false

version=$(tr -d '[:space:]' < "$here/VERSION")
display="FAKUKU Mail"
profile="${NOTARY_PROFILE:-fakuku-notary}"
entitlements="$here/Config/FAKUKUMail.entitlements"

identity="${DEVELOPER_ID:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
fi
if [[ -z "$identity" ]]; then
  echo "release: 키체인에 'Developer ID Application' 인증서가 없습니다. docs/RELEASE.md의 1단계를 보세요." >&2
  exit 1
fi
echo "release: 버전 $version, 서명 $identity"

# 1. 빌드 (build.sh가 ~/Applications에 설치한다) → dist로 복사
"$here/build.sh"
# 서명·DMG는 iCloud와 동기화되지 않는 빌드 폴더에서 한다: 문서·데스크탑 폴더를 iCloud로 동기화하면 macOS가
# 파일에 Finder 정보(com.apple.FinderInfo 등)를 계속 다시 붙여 codesign이 "detritus not allowed"로 거부한다.
out="$HOME/Library/Developer/FAKUKUMail/release"
rm -rf "$out"; mkdir -p "$out"
# --noextattr --norsrc: 확장 속성·리소스 포크 없이 복사
ditto --noextattr --norsrc "$HOME/Applications/$display.app" "$out/$display.app"
app="$out/$display.app"

# 2. Developer ID 서명: 강화된 런타임, 보안 타임스탬프, 권한 파일
xattr -cr "$app"
find "$app" -exec xattr -c {} + 2>/dev/null || true
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
echo "release: 서명 확인 완료"

notarize_and_staple() {
  local file=$1 submit=$1
  if [[ "$file" == *.app ]]; then
    submit="$out/notarize-app.zip"
    ditto -c -k --keepParent "$file" "$submit"
  fi
  echo "release: 공증 요청 $(basename "$file") (몇 분 걸립니다)"
  if ! xcrun notarytool submit "$submit" --keychain-profile "$profile" --wait; then
    echo "release: 공증 실패. 기록 보기: xcrun notarytool log <위의 id> --keychain-profile $profile" >&2
    exit 1
  fi
  xcrun stapler staple "$file"
  if [[ "$submit" != "$file" ]]; then rm -f "$submit"; fi
}

# 3. 앱 공증 (앱 자체에 공증 표를 붙인다: DMG 밖으로 꺼낸 뒤에도 오프라인에서 열린다)
if $notarize; then notarize_and_staple "$app"; fi

# 4. DMG: 앱 + 응용 프로그램 폴더 바로가기
dmg="$out/FAKUKU-Mail-$version.dmg"
stage=$(mktemp -d)
ditto --noextattr --norsrc "$app" "$stage/$display.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$display $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"
codesign --force --timestamp --sign "$identity" "$dmg"

# 5. DMG 공증
if $notarize; then
  notarize_and_staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  spctl --assess --type execute --verbose=2 "$app"
fi
(cd "$out" && shasum -a 256 "$(basename "$dmg")" | tee "$(basename "$dmg").sha256")
# 다 만든 DMG만 저장소의 dist/로 (DMG는 서명이 안에 있어 동기화 꼬리표가 붙어도 괜찮다)
mkdir -p "$here/dist"
cp "$dmg" "$dmg.sha256" "$here/dist/"
dmg="$here/dist/$(basename "$dmg")"
echo "release: 완료 $dmg"

# 6. GitHub 릴리스 (소개 사이트의 다운로드 단추가 releases/latest를 가리킨다)
if $publish; then
  $notarize || { echo "release: 공증하지 않은 DMG는 올리지 않습니다" >&2; exit 1; }
  notes="$here/docs/release-notes/$version.md"
  if [[ -f "$notes" ]]; then
    gh release create "v$version" "$dmg" "$dmg.sha256" --title "FAKUKU Mail $version" --notes-file "$notes"
  else
    gh release create "v$version" "$dmg" "$dmg.sha256" --title "FAKUKU Mail $version" --generate-notes
  fi
  echo "release: GitHub 릴리스 v$version 에 올렸습니다"
fi
