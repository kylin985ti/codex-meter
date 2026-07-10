#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
SOURCE_APP="$ROOT/Codex Meter.app"
DESTINATION_DIR="$HOME/Applications"
DESTINATION_APP="$DESTINATION_DIR/Codex Meter.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  print -u2 -- "没有找到 Codex Meter.app，请保持安装脚本和应用在同一目录。"
  exit 1
fi

mkdir -p "$DESTINATION_DIR"
ditto "$SOURCE_APP" "$DESTINATION_APP"
open "$DESTINATION_APP"

print -- "Codex Meter 已安装到：$DESTINATION_APP"
