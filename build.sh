#!/bin/zsh
# Builds ExchangeMail (shown as "FAKUKU Mail") and installs it to ~/Applications/FAKUKU Mail.app.
# Build products live in ~/Library/Developer/ExchangeMail, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
set -euo pipefail
here=${0:A:h}
name="ExchangeMail"          # executable and build folder (code name)
display="FAKUKU Mail"       # the app people see: bundle file, Dock, menu bar
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

# Siri·단축어(App Intents)용: 컴파일러가 인텐트 정보를 .swiftconstvalues로 내놓게 한다 (Xcode가 하는 일).
intents_protocols="$scratch/intents-protocols.json"
mkdir -p "$scratch"
echo '["AppIntent","AppEntity","AppEnum","EntityQuery","AppShortcutsProvider","DynamicOptionsProvider","TransientAppEntity","AppIntentsPackage"]' > "$intents_protocols"
# swift build에는 -Xfrontend가 없으므로 -Xswiftc로 한 번 더 감싼다.
# 출력 위치를 정해 준다: 위치가 없으면 swift build(전체 모듈 최적화)에서는 파일이 생기지 않았다.
constvalues="$scratch/intents/ExchangeMail.swiftconstvalues"
mkdir -p "$scratch/intents"
rm -f "$constvalues"
# 링커가 남기는 "무엇과 링크했나" 기록: appintentsmetadataprocessor가 AppIntents.framework를 쓰는지 여기서 본다.
intent_flags=(-Xlinker -dependency_info -Xlinker "$scratch/intents/ExchangeMail_dependency_info.dat"
              -Xswiftc -emit-const-values -Xswiftc -emit-const-values-path -Xswiftc "$constvalues"
              -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$intents_protocols")
log=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" "${intent_flags[@]}" 2>&1 || true)
if [[ "$log" == *"unknown argument"* || "$log" == *"unsupported option"* ]]; then
  # 이 컴파일러가 인텐트 정보 추출을 모르면 예전처럼 빌드한다 (Siri 명령만 빠진다).
  echo "warning: 컴파일러가 App Intents 정보 추출을 지원하지 않아 Siri 명령 없이 빌드합니다"
  intent_flags=()
  log=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 || true)
fi
print -r -- "$log" | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --package-path "$here" --scratch-path "$scratch" "${intent_flags[@]}" 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="$HOME/Applications/$display.app"
# Earlier builds were installed under the code name. Keep one copy.
rm -rf "$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
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
