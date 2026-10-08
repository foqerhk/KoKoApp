#!/usr/bin/env bash
# Strict physical-device RE2 matrix. Pair/request/result always use Documents;
# each case remints by restarting the signed Agent through LaunchServices.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1-beta.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$HOME/.local/go/bin:$PATH"

DEVICE="${DEVICE:-00008150-0002212E3CB8401C}"
BUNDLE="${BUNDLE:-com.foqerhk.koko}"
APP="${APP:-/Users/liuwei/Downloads/KoKo/ios/DerivedDataDevice/Build/Products/Debug-iphoneos/KoKo.app}"
PAIR_JSON="${PAIR_JSON:-$HOME/.runeverything/last_pairing.json}"
AGENT_APP="${AGENT_APP:-/Applications/RunEverything.app}"
OUT_DIR="${OUT_DIR:-/tmp/koko-re2-e2e-${DEVICE}}"
CASE="${1:-all}"
AGENT_LOG_FILE=""
mkdir -p "$OUT_DIR"

[[ -d "$APP" ]] || { echo "missing app: $APP" >&2; exit 1; }
[[ -d "$AGENT_APP" ]] || { echo "missing Agent: $AGENT_APP" >&2; exit 1; }

copy_to_docs() {
  local source="$1" destination="$2"
  xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$source" --destination "Documents/$destination" >/dev/null
}

pull_result() {
  local destination="$1"
  rm -f "$destination"
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source Documents/re2-e2e-result.json --destination "$destination" \
    >/dev/null 2>&1
}

restart_agent_and_pair() {
  pkill -f "$AGENT_APP/Contents/MacOS/RunEverything" >/dev/null 2>&1 || true
  rm -f "$PAIR_JSON"
  local i
  for i in $(seq 1 30); do
    pgrep -f "$AGENT_APP/Contents/MacOS/RunEverything" >/dev/null 2>&1 || break
    sleep 0.25
  done
  if [[ -n "$AGENT_LOG_FILE" ]]; then
    rm -f "$AGENT_LOG_FILE"
    launchctl setenv RE_LOG_FILE "$AGENT_LOG_FILE"
  fi
  local launched=0
  for i in $(seq 1 8); do
    if open -a "$AGENT_APP" --args tray; then launched=1; break; fi
    sleep 1
  done
  launchctl unsetenv RE_LOG_FILE
  [[ "$launched" == "1" ]] || { echo "Agent LaunchServices launch failed" >&2; return 1; }
  for i in $(seq 1 50); do
    if [[ -s "$PAIR_JSON" ]] && python3 - "$PAIR_JSON" <<'PY' >/dev/null 2>&1
import json,sys,time
p=json.load(open(sys.argv[1]))
assert p.get("pairing_token") and p.get("device_id") and p.get("relay")
assert int(p.get("expires_at") or 0)-int(time.time()) > 180
PY
    then
      local pid
      pid="$(pgrep -f "$AGENT_APP/Contents/MacOS/RunEverything tray" | head -1)"
      [[ -n "$pid" ]] && [[ "$(ps -p "$pid" -o ppid= | tr -d ' ')" == "1" ]] || {
        echo "Agent is not LaunchServices-owned" >&2
        return 1
      }
      return 0
    fi
    sleep 1
  done
  echo "Agent did not produce a fresh pair" >&2
  return 1
}

strict_gate() {
  local result="$1" name="$2"
  python3 - "$result" "$name" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); name=sys.argv[2]
checks={"ok":p.get("ok") is True, "done":p.get("done") is True,
        "pathOK":p.get("pathOK") is True,
        "gestureOK":((p.get("gesture") or {}).get("gestureOK") is True),
        "chromeOK":((p.get("uiChrome") or {}).get("chromeOK") is True)}
if p.get("testQuality"): checks["qualityOK"]=p.get("qualityOK") is True
if p.get("testMenu"):
    checks["menuOK"]=p.get("menuOK") is True
    checks["filePushOK"]=p.get("filePushOK") is True
    checks["filePullOK"]=p.get("filePullOK") is True
if p.get("testLife"): checks["lifeBackground"]=p.get("lifeBackground") is True
if p.get("test5K"): checks["fiveKOK"]=p.get("fiveKOK") is True
if p.get("testPip"): checks["pipOK"]=p.get("pipOK") is True
if p.get("testGestures"):
    g=p.get("gesture") or {}
    for key in ("remoteCursorFeedback","doubleTap","longPressRightClick","holdDrag",
                "oneFingerSlide","scrollVertical","scrollHorizontal",
                "threeFingerSpaces","threeFingerUpDown","pinchZoom",
                "recognizerDirections"):
        checks["gesture."+key]=g.get(key) is True
bad=[k for k,v in checks.items() if not v]
print(name, "PASS" if not bad else "FAIL", "path=",p.get("pathAfter") or p.get("path"),
      "bad=",bad, "err=",(p.get("error") or "")[:180])
raise SystemExit(1 if bad else 0)
PY
}

run_case() {
  local name="$1" request="$2" timeout="${3:-600}"
  echo "==== CASE $name device=$DEVICE ===="
  AGENT_LOG_FILE="$OUT_DIR/$name-agent.log"
  restart_agent_and_pair
  local stage="$OUT_DIR/stage-$name"
  rm -rf "$stage"; mkdir -p "$stage"
  cp "$PAIR_JSON" "$stage/re2-pair.json"
  python3 - "$stage/re2-e2e-request.json" "$request" <<'PY'
import json,sys
json.dump(json.loads(sys.argv[2]),open(sys.argv[1],"w"))
PY
  local marker
  marker="$(python3 - "$stage/re2-e2e-result.json" <<'PY'
import json,sys,time
m=time.time(); json.dump({"phase":"waiting","done":False,"marker":m},open(sys.argv[1],"w")); print(m)
PY
)"
  copy_to_docs "$stage/re2-pair.json" re2-pair.json
  copy_to_docs "$stage/re2-e2e-request.json" re2-e2e-request.json
  copy_to_docs "$stage/re2-e2e-result.json" re2-e2e-result.json
  xcrun devicectl device process launch --device "$DEVICE" --console \
    --terminate-existing "$BUNDLE" >"$OUT_DIR/$name-console.log" 2>&1 &
  local console_pid=$! deadline=$((SECONDS+timeout)) terminal=0
  local external_pid=""
  if [[ "$name" == "external-life" ]]; then
    (
      local state="$OUT_DIR/external-life-state.json"
      local switch_deadline=$((SECONDS+90))
      while (( SECONDS < switch_deadline )); do
        rm -f "$state"
        xcrun devicectl device copy from --device "$DEVICE" \
          --domain-type appDataContainer --domain-identifier "$BUNDLE" \
          --source Documents/re2-e2e-result.json --destination "$state" \
          >/dev/null 2>&1 || true
        if [[ -s "$state" ]] && python3 - "$state" <<'PY' >/dev/null 2>&1
import json,sys
raise SystemExit(0 if json.load(open(sys.argv[1])).get("phase") == "awaitingExternalBackground" else 1)
PY
        then
          echo "external-life: foreground Settings"
          xcrun devicectl device process launch --device "$DEVICE" com.apple.Preferences >/dev/null \
            || xcrun devicectl device process launch --device "$DEVICE" com.apple.mobilesafari >/dev/null
          sleep 7
          echo "external-life: foreground KoKo"
          xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null
          exit 0
        fi
        sleep 1
      done
      echo "external-life: app never reached switch checkpoint" >&2
      exit 1
    ) &
    external_pid=$!
  fi
  while (( SECONDS < deadline )); do
    sleep 5
    if pull_result "$OUT_DIR/$name-result.json"; then
      if python3 - "$OUT_DIR/$name-result.json" "$marker" <<'PY'
import json,sys
try: p=json.load(open(sys.argv[1]))
except Exception: raise SystemExit(2)
if p.get("phase")=="waiting" and abs(float(p.get("marker") or 0)-float(sys.argv[2]))<.01:
  raise SystemExit(2)
print("phase=",p.get("phase"),"ok=",p.get("ok"),"path=",p.get("pathAfter") or p.get("path"),
      "err=",(p.get("error") or "")[:120])
raise SystemExit(0 if p.get("done") else 2)
PY
      then terminal=1; break; fi
    fi
  done
  if [[ -n "$external_pid" ]]; then
    wait "$external_pid"
  fi
  kill "$console_pid" >/dev/null 2>&1 || true
  (( terminal == 1 )) || { echo "$name timed out" >&2; return 1; }
  strict_gate "$OUT_DIR/$name-result.json" "$name"
  if [[ "$name" == gestures* ]]; then
    python3 - "$AGENT_LOG_FILE" <<'PY'
import re,sys
s=open(sys.argv[1],errors="replace").read()
checks={
 "leftDown": len(re.findall(r"input mouse down=true up=false btn=1",s)) >= 4,
 "leftUp": len(re.findall(r"input mouse down=false up=true btn=1",s)) >= 4,
 "rightDown": "input mouse down=true up=false btn=2" in s,
 "rightUp": "input mouse down=false up=true btn=2" in s,
 "verticalScroll": re.search(r"input mouse .*wheel=-?[1-9][0-9]* wheelH=0",s) is not None,
 "horizontalScroll": re.search(r"input mouse .*wheel=0 wheelH=-?[1-9][0-9]*",s) is not None,
 "spaceNext": "input gesture=space delta=1 ok" in s,
 "spacePrevious": re.search(r"input gesture=space delta=-1 (ok|err=.*fallback Control\+Arrow)",s) is not None,
}
bad=[k for k,v in checks.items() if not v]
print("agent gesture trace", "PASS" if not bad else "FAIL", checks)
raise SystemExit(1 if bad else 0)
PY
  fi
}

xcrun devicectl device install app --device "$DEVICE" "$APP"
mkdir -p "$HOME/.runeverything/xfer"
printf 'KoKo strict remote file pull fixture\n' >"$HOME/.runeverything/xfer/e2e-menu08-pull.txt"

case "$CASE" in
  lan) run_case lan '{"e2e":true,"quality":true,"menu":true}' 900 ;;
  wss) run_case wss '{"e2e":true,"forceWSS":true,"quality":true,"menu":true}' 1200 ;;
  udp-relay) run_case udp-relay '{"e2e":true,"forceUDP":true,"stripLAN":true,"quality":true,"menu":true}' 1000 ;;
  life) run_case life '{"e2e":true,"testLife":true}' 500 ;;
  external-life) run_case external-life '{"e2e":true,"externalLife":true,"forceUDP":true,"stripLAN":true}' 500 ;;
  weak-relay) run_case weak-relay '{"e2e":true,"forceUDP":true,"stripLAN":true}' 400 ;;
  gestures) run_case gestures '{"e2e":true,"gestures":true}' 500 ;;
  gestures-relay) run_case gestures-relay '{"e2e":true,"gestures":true,"forceUDP":true,"stripLAN":true}' 600 ;;
  gestures-wss) run_case gestures-wss '{"e2e":true,"gestures":true,"forceWSS":true,"stripLAN":true}' 600 ;;
  pip) run_case pip '{"e2e":true,"pip":true}' 600 ;;
  pip-relay) run_case pip-relay '{"e2e":true,"pip":true,"forceUDP":true,"stripLAN":true}' 700 ;;
  5k) run_case 5k '{"e2e":true,"test5K":true}' 900 ;;
  5k-relay) run_case 5k-relay '{"e2e":true,"forceUDP":true,"stripLAN":true,"test5K":true}' 900 ;;
  all)
    "$0" lan
    "$0" wss
    "$0" udp-relay
    "$0" life
    "$0" weak-relay
    ;;
  *) echo "usage: $0 lan|wss|udp-relay|life|external-life|weak-relay|gestures|gestures-relay|gestures-wss|pip|pip-relay|5k|5k-relay|all" >&2; exit 2 ;;
esac
