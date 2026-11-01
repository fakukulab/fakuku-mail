#!/bin/zsh
# Snapshots of every page in light and dark, in demo mode (sample mailbox, no sign-in), on a fresh /tmp store.
# Usage: tools/snap.sh                              all pages
#        APP_SNAPSHOT_PAGES=inbox,compose,settings tools/snap.sh
set -u
app="$HOME/Applications/FAKUKU Mail.app/Contents/MacOS/ExchangeMail"
store=/tmp/ExchangeMail-test
shots=/tmp/ExchangeMail-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.example.exchangemail.savedState
# Demo signatures are only seeded into an empty store, so start from nothing.
rm -rf $store $shots
APP_STORE=$store APP_SEED=1 APP_SNAPSHOT=$shots $app
