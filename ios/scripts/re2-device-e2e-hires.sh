#!/usr/bin/env bash
# Four-path + virtual 8K/16K RE2 E2E (Agent must run with RE_VDISPLAY=8k|16k).
# Agent install: RunEverything/docs/agent-macos-local-dev.md
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1-beta.app/Contents/Developer}"
DEVICE="${DEVICE:-00008150-0002212E3CB8401C}"
BUNDLE="${BUNDLE:-com.foqerhk.koko}"
APP="${APP:-/Users/liuwei/Downloads/KoKo/ios/DerivedDataDevice/Build/Products/Debug-iphoneos/KoKo.app}"
PAIR_JSON="${PAIR_JSON:-$HOME/.runeverything/last_pairing.json}"
OUT_DIR="${OUT_DIR:-/tmp/koko-re2-e2e-hires}"
MODE="${1:-16k}"   # 8k | 16k
mkdir -p "$OUT_DIR"

if [[ ! -f "$PAIR_JSON" ]]; then
  echo "missing pair json: $PAIR_JSON" >&2
  exit 1
fi
if [[ ! -d "$APP" ]]; then
  echo "missing app: $APP (build first)" >&2
  exit 1
fi

case "$MODE" in
  8k)  HI_FLAG=test8K; HI_ARG=-RE2E2E8K; HI_KEY=eightKOK ;;
  16k) HI_FLAG=test16K; HI_ARG=-RE2E2E16K; HI_KEY=sixteenKOK ;;
  *) echo "usage: $0 8k|16k" >&2; exit 2 ;;
esac

push_request() {
  local name="$1"
  shift
  python3 - "$OUT_DIR/$name-request.json" "$HI_FLAG" "$@" <<'PY'
import json, sys
out, flag = sys.argv[1], sys.argv[2]
req = {"e2e": True, flag: True}
for a in sys.argv[3:]:
    if a == "forceWSS": req["forceWSS"] = True
    elif a == "forceUDP": req["forceUDP"] = True
    elif a == "stripLAN": req["stripLAN"] = True
    elif a == "quality": req["quality"] = True
json.dump(req, open(out, "w"))
print(json.dumps(req))
PY
  xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$OUT_DIR/$name-request.json" \
    --destination Documents/re2-e2e-request.json
  cp "$PAIR_JSON" "$OUT_DIR/re2-pair.json"
  xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$OUT_DIR/re2-pair.json" \
    --destination Documents/re2-pair.json
  # Invalidate stale result so we never accept a previous run.
  python3 - <<'PY' > "$OUT_DIR/re2-e2e-result.stale.json"
import json
json.dump({"ok": False, "phase": "pending", "stale": True}, open("/dev/stdout","w"))
PY
  xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$OUT_DIR/re2-e2e-result.stale.json" \
    --destination Documents/re2-e2e-result.json || true
}

remint_pair() {
  # Pairing token is single-use after a successful connect — remint between cases.
  echo "==> remint pairing (RE_VDISPLAY=$MODE)"
  pkill -f '/Applications/RunEverything.app/Contents/MacOS/RunEverything tray' >/dev/null 2>&1 || true
  sleep 1
  rm -f "$PAIR_JSON"
  # Preserve RunEverything as the TCC-responsible process while passing the
  # virtual-display mode through launchd to LaunchServices.
  launchctl setenv RE_VDISPLAY "$MODE"
  open -a /Applications/RunEverything.app --args tray
  local i
  for i in $(seq 1 40); do
    if [[ -f "$PAIR_JSON" ]]; then
      launchctl unsetenv RE_VDISPLAY
      local pid
      pid="$(pgrep -f '/Applications/RunEverything.app/Contents/MacOS/RunEverything tray' | head -1)"
      [[ -n "$pid" && "$(ps -p "$pid" -o ppid= | tr -d ' ')" == "1" ]] || return 1
      python3 -c 'import json,time;p=json.load(open("'"$PAIR_JSON"'"));print("lan",p.get("lan"),"exp",int((p.get("expires_at")or 0)-time.time()))'
      return 0
    fi
    sleep 1
  done
  launchctl unsetenv RE_VDISPLAY
  echo "remint failed: no pairing/vdisplay" >&2
  return 1
}

run_case() {
  local name="$1"; shift
  echo "==== CASE $name ($MODE) ===="
  remint_pair || return 1
  rm -f "$OUT_DIR/$name-result.json"
  xcrun devicectl device process terminate --device "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 1
  push_request "$name" "$@"
  # No --environment on this Xcode; request+pair files + argv drive E2E.
  # --terminate-existing forces a cold start so didStartThisProcess resets.
  xcrun devicectl device process launch --device "$DEVICE" \
    --terminate-existing \
    "$BUNDLE" -- -RE2E2E "$HI_ARG" 2>&1 | tee "$OUT_DIR/$name-launch.txt" || true

  # 16K soft-decode paint can take >2 min before the first full frame.
  local wait_s=300
  [[ "$MODE" == "16k" ]] && wait_s=480
  local deadline=$((SECONDS + wait_s))
  while (( SECONDS < deadline )); do
    sleep 10
    xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --source Documents/re2-e2e-result.json \
      --destination "$OUT_DIR/$name-result.json" >/dev/null 2>&1 || true
    if [[ -f "$OUT_DIR/$name-result.json" ]]; then
      if python3 - "$OUT_DIR/$name-result.json" "$HI_FLAG" "$HI_KEY" "$name" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
flag, key, name = sys.argv[2], sys.argv[3], sys.argv[4]
print(name, "phase=", p.get("phase"), "ok=", p.get("ok"),
      "hi=", p.get(key), "pic=", p.get("picAfterHiRes"),
      "desk=", p.get("deskAfterHiRes"),
      "path=", p.get("pathAfter") or p.get("pathAfterHiRes"),
      "err=", p.get("error"))
if p.get("stale"):
    raise SystemExit(3)
# Wait for terminal phase (done) or hard error — not sixteenKOK alone
# (that flips at after16K before freeze/ramp finish).
if p.get("done") or p.get("phase") == "done":
    raise SystemExit(0)
if p.get("error") and p.get("phase") in ("done", "pairing", "failed", None):
    raise SystemExit(0)
if p.get("error") and p.get("phase") not in ("hiRes8K", "hiRes16K", "after8K", "after16K", "afterRamp", "afterHold"):
    raise SystemExit(0)
raise SystemExit(3)
PY
      then
        break
      fi
    fi
  done

  if [[ -f "$OUT_DIR/$name-result.json" ]]; then
    python3 - "$OUT_DIR/$name-result.json" "$HI_KEY" "$name" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
key, name = sys.argv[2], sys.argv[3]
print(name, "FINAL ok=", p.get("ok"), "path=", p.get("pathAfter") or p.get("path"),
      "hiOK=", p.get(key), "pic=", p.get("picAfterHiRes"),
      "desk=", p.get("deskAfterHiRes"), "err=", p.get("error"))
PY
  else
    echo "$name MISSING_RESULT"
  fi
}

xcrun devicectl device install app --device "$DEVICE" "$APP"

run_case "lan_${MODE}"
run_case "wss_${MODE}" forceWSS
run_case "udp_relay_${MODE}" forceUDP stripLAN
run_case "udp_force_${MODE}" forceUDP

echo "==== SUMMARY $MODE ===="
fail=0
for f in "$OUT_DIR"/lan_${MODE}-result.json \
         "$OUT_DIR"/wss_${MODE}-result.json \
         "$OUT_DIR"/udp_relay_${MODE}-result.json \
         "$OUT_DIR"/udp_force_${MODE}-result.json; do
  [[ -f "$f" ]] || { echo "missing $f"; fail=1; continue; }
  if ! python3 - "$f" "$HI_KEY" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
key = sys.argv[2]
ok = bool(p.get("ok")) and bool(p.get(key))
print(sys.argv[1]+":", "ok=", ok, "path=", p.get("pathAfter") or p.get("path"),
      "pic=", p.get("picAfterHiRes"), "desk=", p.get("deskAfterHiRes"),
      "err=", p.get("error"))
sys.exit(0 if ok else 1)
PY
  then
    fail=1
  fi
done
exit "$fail"
