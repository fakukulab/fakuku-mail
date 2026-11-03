#!/bin/zsh
# Snapshots of every page in light and dark, in demo mode (sample mailbox, no sign-in), on a fresh /tmp store.
# Usage: tools/snap.sh                              all pages
#        APP_SNAPSHOT_PAGES=inbox,compose,settings tools/snap.sh
set -u
app="$HOME/Applications/FAKUKU Mail.app/Contents/MacOS/FAKUKUMail"
store=/tmp/FAKUKUMail-test
shots=/tmp/FAKUKUMail-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.fakukulab.fakukumail.savedState
# Demo signatures are only seeded into an empty store, so start from nothing.
rm -rf $store $shots
# APP_LANG=en tools/snap.sh 로 영어 화면을 찍는다 (기본은 시스템 언어).
lang_args=()
[[ -n "${APP_LANG:-}" ]] && lang_args=(-AppleLanguages "(${APP_LANG})")
APP_STORE=$store APP_SEED=1 APP_SNAPSHOT=$shots $app "${lang_args[@]}"
