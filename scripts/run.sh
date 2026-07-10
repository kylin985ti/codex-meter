#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/Codex Meter.app"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build.sh" >/dev/null
fi

open "$APP"
