#!/bin/zsh
# 자동 업데이트(Sparkle, 1.0.2): Sparkle.framework를 앱 안(Contents/Frameworks)에 넣고, 안쪽부터 서명한다.
# 앱 자체 서명은 부른 쪽(build.sh, tools/release.sh)이 이 다음에 한다.
#
# Usage: tools/embed_sparkle.sh <앱> <서명 이름 또는 -> [--release] [빌드 결과 폴더]
#   --release  배포용: 강화된 런타임(-o runtime)과 보안 타임스탬프 (공증에 필요)
#   빌드 결과 폴더를 주면 거기서 Sparkle.framework를 복사한다. 없으면 이미 들어 있는 것을 다시 서명만 한다.
set -euo pipefail
app=$1; identity=$2; shift 2
release=false; bin_dir=""
for a in "$@"; do
  if [[ "$a" == "--release" ]]; then release=true; else bin_dir=$a; fi
done
fw="$app/Contents/Frameworks/Sparkle.framework"
exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"

if [[ -n "$bin_dir" ]]; then
  [[ -d "$bin_dir/Sparkle.framework" ]] || { echo "embed_sparkle: $bin_dir/Sparkle.framework 이 없습니다" >&2; exit 1; }
  mkdir -p "$app/Contents/Frameworks"
  rm -rf "$fw"
  ditto --noextattr --norsrc "$bin_dir/Sparkle.framework" "$fw"
  # 샌드박스를 쓰지 않는 앱은 XPC 서비스가 필요 없다 (Sparkle 문서: 지워도 된다). 서명할 것이 줄어든다.
  rm -rf "$fw/Versions/B/XPCServices"
  # 실행 파일이 Contents/Frameworks에서 Sparkle을 찾게 한다 (swift build는 @loader_path만 넣는다)
  if ! otool -l "$exe" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
  fi
fi
[[ -d "$fw" ]] || { echo "embed_sparkle: 앱 안에 Sparkle.framework가 없습니다" >&2; exit 1; }

flags=(--force --sign "$identity")
if $release; then
  flags+=(--options runtime --timestamp)
elif [[ "$identity" != "-" ]]; then
  flags+=(--options runtime)
fi
# 안쪽부터: 설치 도우미, 업데이트 창 앱, 프레임워크
codesign "${flags[@]}" "$fw/Versions/B/Autoupdate"
codesign "${flags[@]}" "$fw/Versions/B/Updater.app"
codesign "${flags[@]}" "$fw"
