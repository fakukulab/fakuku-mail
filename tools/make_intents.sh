#!/bin/zsh
# App Intents(Siri·단축어) 메타데이터를 만든다: <app>/Contents/Resources/Metadata.appintents
# Xcode는 빌드 중에 appintentsmetadataprocessor를 부른다. 이 앱은 swift build로 빌드하므로 여기서 직접 부른다.
# Usage: tools/make_intents.sh <App.app> <build scratch dir> <app sources dir>
set -euo pipefail
app=$1; products=$2; sources=$3
name="ExchangeMail"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 컴파일러가 남긴 인텐트 정보(.swiftconstvalues) 목록
# $products(…/build/release)는 …/arm64-apple-macosx/release를 가리키는 심볼릭 링크다: -L로 따라간다.
# build.sh가 정한 자리(intents/)를 먼저, 없으면 빌드 폴더 전체에서 찾는다.
if [[ -s "$products/intents/$name.swiftconstvalues" ]]; then
  echo "$products/intents/$name.swiftconstvalues" > "$work/constvalues.txt"
else
  find -L "$products" -name "*.swiftconstvalues" -path "*$name*" > "$work/constvalues.txt" 2>/dev/null || true
fi
echo "make_intents: 인텐트 정보 파일 $(wc -l < "$work/constvalues.txt" | tr -d ' ')개"
if [[ ! -s "$work/constvalues.txt" ]]; then
  echo "make_intents: .swiftconstvalues가 없습니다 (swift build에 -emit-const-values가 빠졌나요?)" >&2
  exit 1
fi
find "$sources" -name '*.swift' > "$work/sources.txt"

# 링커의 dependency_info (build.sh가 -Xlinker -dependency_info로 남긴다)
deps="$products/intents/$name"_dependency_info.dat
if [[ ! -s "$deps" ]]; then
  echo "make_intents: 링커 기록($deps)이 없습니다. ./build.sh로 다시 빌드해 주세요." >&2
  exit 1
fi
toolchain=$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcode_version=$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')
arch=$(uname -m)

echo "make_intents: appintentsmetadataprocessor 실행 (Xcode ${xcode_version:-?}, $arch)"
xcrun appintentsmetadataprocessor \
  --toolchain-dir "$toolchain" \
  --module-name "$name" \
  --sdk-root "$sdk" \
  --xcode-version "${xcode_version:-17A1}" \
  --platform-family macOS \
  --deployment-target 26.0 \
  --bundle-identifier "$bundle_id" \
  --output "$app/Contents/Resources" \
  --target-triple "$arch-apple-macos26.0" \
  --binary-file "$app/Contents/MacOS/$name" \
  --dependency-file "$deps" \
  --stringsdata-file "$work/ExtractedAppShortcutsMetadata.stringsdata" \
  --source-file-list "$work/sources.txt" \
  --swift-const-vals-list "$work/constvalues.txt" \
  --compile-time-extraction \
  --deployment-aware-processing

if [[ -d "$app/Contents/Resources/Metadata.appintents" ]]; then
  echo "Siri 명령: Metadata.appintents 만듦"
else
  echo "make_intents: Metadata.appintents가 생기지 않았습니다" >&2
  exit 1
fi
