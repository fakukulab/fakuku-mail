#!/bin/zsh
# Runs the in-app self-test in demo mode against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
# 켜져 있는 FAKUKU Mail(실제 계정)이 있으면 셀프 테스트용 앱이 메인 창을 띄우지 못한다: 먼저 끈다.
if pgrep -x FAKUKUMail >/dev/null; then
  echo "selftest: 켜져 있는 FAKUKU Mail을 끕니다 (셀프 테스트와 함께 켤 수 없습니다)"
  osascript -e 'tell application id "com.fakukulab.fakukumail" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x FAKUKUMail >/dev/null || break; sleep 0.5; done
  pkill -x FAKUKUMail 2>/dev/null || true
  sleep 1
fi
rm -rf ~/Library/Saved\ Application\ State/com.fakukulab.fakukumail.savedState
store=/tmp/FAKUKUMail-self
rm -rf $store
# 검사 글자가 한국어라 한국어로 돌린다 (영어 표는 셀프 테스트 안에서 따로 본다).
app="$HOME/Applications/FAKUKU Mail.app"
out=$(mktemp -t fakuku-selftest)
APP_STORE=$store "$app/Contents/MacOS/FAKUKUMail" --selftest -AppleLanguages "(ko)" > "$out" 2>&1 &
pid=$!
tail -n +1 -f "$out" & tailer=$!   # 결과 줄을 바로바로 보인다
# 터미널에서 켠 앱은 macOS가 앞으로 가져오지 않아 메인 창이 생기지 않을 때가 있다 (검사 0개로 4분 뒤 TIMEOUT).
# 창이 안 떴으면 Dock 아이콘을 누른 것처럼 한 번 깨운다. 셀프 테스트 앱이 아직 켜져 있을 때만 (아니면 실제 앱이 켜진다).
for _ in {1..10}; do grep -q "메인 창이 떴습니다" "$out" && break; sleep 0.5; done
if ! grep -q "메인 창이 떴습니다" "$out" && kill -0 $pid 2>/dev/null; then
  open "$app"
fi
wait $pid; code=$?
sleep 0.2; kill $tailer 2>/dev/null
rm -f "$out"
exit $code
