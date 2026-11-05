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
APP_STORE=$store "$HOME/Applications/FAKUKU Mail.app/Contents/MacOS/FAKUKUMail" --selftest -AppleLanguages "(ko)"
