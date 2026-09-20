#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGES="$ROOT/Packages"
BARE_CACHE="${SPM_BARE_CACHE:-$ROOT/DerivedData/SourcePackages/repositories}"
GHPROXY="${GHPROXY:-https://ghproxy.net/https://github.com}"

mkdir -p "$PACKAGES"

clone_or_skip() {
  local dest="$1"
  local url="$2"
  local branch="${3:-}"
  if [ -f "$dest/Package.swift" ]; then
    echo "OK $(basename "$dest")"
    return 0
  fi
  rm -rf "$dest"
  if [ -n "$branch" ]; then
    git clone --depth 1 --branch "$branch" "$url" "$dest"
  else
    git clone --depth 1 "$url" "$dest"
  fi
  echo "CLONED $(basename "$dest")"
}

clone_from_bare_or_remote() {
  local bare_name="$1"
  local dest_name="$2"
  local branch="$3"
  local remote_url="$4"
  local dest="$PACKAGES/$dest_name"
  if [ -f "$dest/Package.swift" ]; then
    echo "OK $dest_name"
    return 0
  fi
  if [ -d "$BARE_CACHE/$bare_name" ]; then
    rm -rf "$dest"
    git clone --shared --branch "$branch" --single-branch "$BARE_CACHE/$bare_name" "$dest" || true
  fi
  if [ ! -f "$dest/Package.swift" ]; then
    clone_or_skip "$dest" "$remote_url" "$branch"
  else
    echo "OK $dest_name (from bare cache)"
  fi
}

# Top-level libraries
clone_or_skip "$PACKAGES/SwiftTerm" "https://github.com/migueldeicaza/SwiftTerm.git"
clone_or_skip "$PACKAGES/Citadel" "https://github.com/scientific-creative/Citadel.git"

# Transitive deps (local path wiring; helps offline / restricted networks)
clone_from_bare_or_remote "swift-nio-ssh-ccb6c93f" "swift-nio-ssh" "citadel2" "$GHPROXY/Wellz26/swift-nio-ssh.git"
clone_from_bare_or_remote "swift-nio-a9bb6d62" "swift-nio" "main" "$GHPROXY/apple/swift-nio.git"
clone_from_bare_or_remote "swift-log-ba8887eb" "swift-log" "main" "$GHPROXY/apple/swift-log.git"
clone_from_bare_or_remote "BigInt-7b87d7d1" "BigInt" "master" "$GHPROXY/attaswift/BigInt.git"
clone_from_bare_or_remote "swift-crypto-7e0614ea" "swift-crypto" "main" "$GHPROXY/apple/swift-crypto.git"
clone_from_bare_or_remote "ColorizeSwift-b59948c2" "ColorizeSwift" "master" "$GHPROXY/mtynior/ColorizeSwift.git"
clone_from_bare_or_remote "swift-atomics-7429e549" "swift-atomics" "main" "$GHPROXY/apple/swift-atomics.git"
clone_from_bare_or_remote "swift-asn1-7065ad2c" "swift-asn1" "main" "$GHPROXY/apple/swift-asn1.git"

if [ ! -f "$PACKAGES/swift-collections/Package.swift" ]; then
  clone_or_skip "$PACKAGES/swift-collections" "$GHPROXY/apple/swift-collections.git" "1.1.4"
fi
if [ ! -f "$PACKAGES/swift-system/Package.swift" ]; then
  clone_or_skip "$PACKAGES/swift-system" "$GHPROXY/apple/swift-system.git" "1.4.0"
fi

# Ensure Package.swift files use local path deps (idempotent patches applied once by KoKo)
ensure_local_manifest_note() {
  echo "Local SPM packages ready under Packages/"
}

ensure_local_manifest_note

# Rewrite Package.swift files to use sibling path deps (offline-friendly).
bash "$ROOT/scripts/apply-local-spm-patches.sh"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec "$ROOT/project.yml"
else
  echo "请安装 XcodeGen: brew install xcodegen"
  echo "或手动在 Xcode 中打开 KoKo.xcodeproj"
fi

echo "完成。运行: open $ROOT/KoKo.xcodeproj"
