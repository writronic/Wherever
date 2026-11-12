#!/bin/sh
set +x
set -eu
umask 022
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec /usr/bin/ruby "$ROOT/scripts/release-macos.rb" "$@" </dev/null
