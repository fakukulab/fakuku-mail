#!/bin/zsh
# Runs the in-app self-test in demo mode against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.fakukulab.fakukumail.savedState
store=/tmp/ExchangeMail-self
rm -rf $store
# 검사 글자가 한국어라 한국어로 돌린다 (영어 표는 셀프 테스트 안에서 따로 본다).
APP_STORE=$store "$HOME/Applications/FAKUKU Mail.app/Contents/MacOS/ExchangeMail" --selftest -AppleLanguages "(ko)"
