#!/bin/zsh
# Runs the in-app self-test in demo mode against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.example.exchangemail.savedState
store=/tmp/ExchangeMail-self
rm -rf $store
APP_STORE=$store "$HOME/Applications/FAKUKU Mail.app/Contents/MacOS/ExchangeMail" --selftest
