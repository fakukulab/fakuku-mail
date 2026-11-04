#!/bin/zsh
# 소개 페이지(site/)의 스크린샷과 앱 아이콘을 실제 앱으로 만든다 (데모 메일상자라 실제 메일이 찍히지 않는다).
# 맥에서: ./build.sh 한 뒤 tools/site-shots.sh → site/images/ 를 커밋하고 push (GitHub Pages가 다시 올린다).
set -euo pipefail
here=${0:A:h:h}
out="$here/site/images"
shots=/tmp/FAKUKUMail-shots
mkdir -p "$out/en"
pages=(inbox compose message settings-viewing)

take() {   # $1: 언어(ko, en)  $2: 넣을 폴더
  APP_LANG=$1 APP_SNAPSHOT_PAGES=inbox,compose,message,settings "$here/tools/snap.sh" >/dev/null
  for p in $pages; do
    for m in light dark; do
      [[ -f "$shots/$p-$m.png" ]] || { echo "없음: $shots/$p-$m.png"; continue; }
      # 웹에 맞게 긴 변 1600px로 줄인다
      sips -Z 1600 "$shots/$p-$m.png" --out "$2/$p-$m.png" >/dev/null
    done
  done
}

take ko "$out"
take en "$out/en"
# 앱 아이콘 (build.sh가 만든 Resources/AppIcon.icns에서)
if [[ -f "$here/Resources/AppIcon.icns" ]]; then
  sips -s format png -Z 512 "$here/Resources/AppIcon.icns" --out "$out/icon.png" >/dev/null
fi
ls -1 "$out" "$out/en"
echo "site/images 를 커밋하고 push하세요."
