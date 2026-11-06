#!/bin/zsh
# Builds ExchangeMail (shown as "FAKUKU Mail") and installs it to ~/Applications/FAKUKU Mail.app.
# Build products live in ~/Library/Developer/FAKUKUMail, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
set -euo pipefail
here=${0:A:h}
name="ExchangeMail"          # Swift target (code name): the build product
exe="FAKUKUMail"            # program inside the app (Info.plist CFBundleExecutable) and build folder
display="FAKUKU Mail"       # the app people see: bundle file, Dock, menu bar
scratch="$HOME/Library/Developer/$exe/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
# Developer ID가 있으면 그것으로: 배포본(tools/release.sh)과 같은 서명이라 키체인의 로그인 정보를 함께 쓴다
# (서명이 다르면 macOS가 "키체인 … 사용하려고 합니다" 창을 띄운다).
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
fi
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

# Siri·단축어(App Intents)용: 컴파일러가 인텐트 정보를 .swiftconstvalues로 내놓게 한다 (Xcode가 하는 일).
# 예전 이름의 빌드 폴더(~/Library/Developer/ExchangeMail)는 캐시일 뿐이라 지운다.
rm -rf "$HOME/Library/Developer/ExchangeMail"
intents_protocols="$scratch/intents-protocols.json"
mkdir -p "$scratch"
echo '["AppIntent","AppEntity","AppEnum","EntityQuery","AppShortcutsProvider","DynamicOptionsProvider","TransientAppEntity","AppIntentsPackage"]' > "$intents_protocols"
# swift build에는 -Xfrontend가 없으므로 -Xswiftc로 한 번 더 감싼다.
# 출력 위치를 정해 준다: 위치가 없으면 swift build(전체 모듈 최적화)에서는 파일이 생기지 않았다.
constvalues="$scratch/intents/ExchangeMail.swiftconstvalues"
mkdir -p "$scratch/intents"
# 지우지 않는다: 바뀐 코드가 없으면 swift build가 다시 만들지 않아(0.1초 빌드) Siri 정보가 빠진다.
# 이 파일은 빌드할 때마다 덮어쓴다.
# 링커가 남기는 "무엇과 링크했나" 기록: appintentsmetadataprocessor가 AppIntents.framework를 쓰는지 여기서 본다.
intent_flags=(-Xlinker -dependency_info -Xlinker "$scratch/intents/ExchangeMail_dependency_info.dat"
              -Xswiftc -emit-const-values -Xswiftc -emit-const-values-path -Xswiftc "$constvalues"
              -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$intents_protocols")
log=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" "${intent_flags[@]}" 2>&1 || true)
if [[ "$log" == *"unable to open dependencies file"* || "$log" == *"dependency info modifications"* ]]; then
  # 새 빌드 시스템(Xcode 27의 swift build)은 링커 기록을 스스로 남기며, 위치를 바꾸면 링크가 실패한다.
  # 링커 기록 위치 지정만 빼고 다시 빌드한다. make_intents.sh는 빌드 시스템이 남긴 기록을 찾아 쓴다.
  intent_flags=("${(@)intent_flags[5,-1]}")
  log=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" "${intent_flags[@]}" 2>&1 || true)
fi
if [[ "$log" == *"unknown argument"* || "$log" == *"unsupported option"* ]]; then
  # 이 컴파일러가 인텐트 정보 추출을 모르면 예전처럼 빌드한다 (Siri 명령만 빠진다).
  echo "warning: 컴파일러가 App Intents 정보 추출을 지원하지 않아 Siri 명령 없이 빌드합니다"
  intent_flags=()
  log=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 || true)
fi
print -r -- "$log" | grep -E "error|warning|Build complete" | grep -v "^\[" || true
# 실행 파일 위치는 빌드 시스템에 묻는다: 새 빌드 시스템(Xcode 27)은 "$scratch/$config"가 아닌 곳에 쓸 수 있고,
# 그러면 그 자리에 남은 예전 실행 파일을 검사하고 설치하게 된다.
bin_dir=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" --show-bin-path 2>/dev/null || true)
[[ -n "$bin_dir" ]] || bin_dir="$scratch/$config"
bin="$bin_dir/$name"
[[ -x "$bin" ]] || { echo "build failed: $bin 이 없습니다"; exit 1; }
# 링크가 실패해도 예전 실행 파일이 남아 있으면 그대로 설치될 수 있다: 빌드 실패면 멈춘다.
if [[ "$log" == *"error: Build failed"* || "$log" == *"failed with a nonzero exit code"* ]]; then
  echo "build failed (위 error 줄을 보세요)"
  exit 1
fi
# swift build can report success while an edited file failed to compile. Catch that.
# 실행 파일보다 새 소스가 있으면 한 번 더 빌드한다: 정말 컴파일이 안 됐다면 이번에 error가 나온다.
# error 없이 끝나면 시각만 어긋난 것이다 (iCloud로 동기화되는 문서 폴더는 빌드 뒤에 파일 시각을 다시 찍기도 한다).
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "note: 실행 파일보다 새 소스가 있어 다시 빌드해 확인합니다 ($stale)"
  again=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" "${intent_flags[@]}" 2>&1 || true)
  if [[ "$again" == *"error:"* || "$again" == *"failed with a nonzero exit code"* ]]; then
    echo "build failed: binary is older than $stale"
    print -r -- "$again" | grep -E "error" | head -20
    exit 1
  fi
  echo "note: 다시 빌드해도 오류가 없습니다. 파일 시각만 어긋났으므로 계속합니다"
fi

app="$HOME/Applications/$display.app"
# Earlier builds were installed under the code name. Keep one copy.
rm -rf "$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$exe"
# Azure 앱 등록 번호(멀티 테넌트): 환경 변수 AZURE_CLIENT_ID, 없으면 Config/azure-client-id.txt (# 줄은 설명).
# 비어 있으면 사용자가 설정 > 계정 > 고급에 직접 넣어야 한다.
client_id="${AZURE_CLIENT_ID:-}"
if [[ -z "$client_id" && -f "$here/Config/azure-client-id.txt" ]]; then
  client_id=$(grep -v '^[[:space:]]*#' "$here/Config/azure-client-id.txt" | tr -d '[:space:]')
fi
[[ "$client_id" =~ ^[0-9A-Fa-f-]*$ ]] || { echo "Config/azure-client-id.txt: 클라이언트 ID 형식이 아닙니다"; exit 1; }
[[ -n "$client_id" ]] || echo "warning: Azure 클라이언트 ID가 없습니다 (Config/azure-client-id.txt). 사용자가 직접 넣어야 로그인할 수 있습니다."
# 버전: 저장소의 VERSION 파일 (배포할 때 tools/release.sh가 같은 값을 쓴다)
version=$(tr -d '[:space:]' < "$here/VERSION" 2>/dev/null || echo 0.0.0)
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" -e "s/__VERSION__/$version/" -e "s/__AZURE_CLIENT_ID__/$client_id/" \
  "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
# 화면 글자: 시스템 언어가 한국어면 한국어, 영어(그 밖의 언어 포함)면 영어. 메뉴 막대의 시스템 항목도 따라간다.
cp -R "$here/Localization/"*.lproj "$app/Contents/Resources/"
# Siri·단축어 메타데이터 (Contents/Resources/Metadata.appintents). 실패해도 앱은 설치한다.
"$here/tools/make_intents.sh" "$app" "$scratch" "$here/Sources/ExchangeMail" || echo "warning: Siri 명령 메타데이터를 만들지 못했습니다 (앱은 정상 설치)"
xattr -cr "$app"
codesign --force --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$display\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
