#!/bin/zsh
# Opens the app in demo mode (sample mailbox, no sign-in) to look around. Nothing touches your real account.
set -u
store=/tmp/ExchangeMail-demo
rm -rf $store
APP_STORE=$store APP_SEED=1 "$HOME/Applications/FAKUKU Mail.app/Contents/MacOS/ExchangeMail" &
