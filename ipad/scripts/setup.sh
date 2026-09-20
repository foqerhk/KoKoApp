#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/../ios"

echo "==> KoKoPad setup: reuse iOS SPM packages"
bash "$IOS/scripts/setup.sh"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec "$ROOT/project.yml"
else
  echo "请安装 XcodeGen: brew install xcodegen"
fi

echo "完成。运行: open $ROOT/KoKoPad.xcodeproj"
