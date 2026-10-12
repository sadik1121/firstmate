#!/usr/bin/env bash
# Live driver: named fm-lab-* Herdr session, new vs base launcher, capture-pipe EOF.
set -u
ROOT=$1; BASE=$2; SCR=$3
LAB="$ROOT/bin/fm-herdr-lab.sh"
NAME=$("$LAB" name fdleak)
NAME2=""
DEFAULT_BEFORE=$(herdr session list --json | jq -c '[.sessions[]|select(.default)|{name,running,socket_path}]')
cleanup() {
  [ -n "$NAME2" ] && { echo "## teardown $NAME2"; "$LAB" teardown "$NAME2"; echo "teardown rc=$?"; }
  echo "## teardown $NAME"; "$LAB" teardown "$NAME"; echo "teardown rc=$?"
  DEFAULT_AFTER=$(herdr session list --json | jq -c '[.sessions[]|select(.default)|{name,running,socket_path}]')
  echo "default before: $DEFAULT_BEFORE"; echo "default after:  $DEFAULT_AFTER"
  [ "$DEFAULT_BEFORE" = "$DEFAULT_AFTER" ] && echo "DEFAULT SESSION UNCHANGED" || echo "DEFAULT SESSION CHANGED!"
  herdr session list --json | jq -c '[.sessions[].name]'
}
trap cleanup EXIT
echo "lab session: $NAME"

server_report() { # <session>
  local s=$1 pid ppid pcmd
  echo "status running: $("$LAB" run "$s" status --json 2>/dev/null | jq -r '.server.running')"
  pid=$(pgrep -f "server --session $s\$" | head -1)
  [ -n "$pid" ] || { echo "server pid: <none>"; return; }
  ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  pcmd=$(ps -o comm= -p "$ppid")
  echo "server pid=$pid argv=[$(ps -o args= -p "$pid")] parent=$ppid ($pcmd)"
  case "$pcmd" in *bash*) echo "WAITING BASH PARENT PRESENT" ;; *) echo "no bash parent" ;; esac
  echo "server fds: $(lsof -p "$pid" -a -d 3-255 -F ft 2>/dev/null | paste -sd' ' -)"
  echo "server pipe fds: $(lsof -p "$pid" -a -d 3-255 2>/dev/null | awk '$5=="PIPE"' | wc -l | tr -d ' ')"
  echo "server env (filtered): $(ps -E -o command= -p "$pid" | tr ' ' '\n' | grep -E '^(FM_HOME|FM_ROOT_OVERRIDE|CLAUDECODE|CURSOR_AGENT|HERDR_SESSION|FM_LIVE_MARK)=' | paste -sd' ' -)"
}

# Run <bash> <script> in background; wait up to <secs> for capture to finish.
captured() { # <label> <secs> <bash> <script>
  local label=$1 secs=$2 sh=$3 script=$4 out pid t=0; out="$SCR/$label.out"
  rm -f "$out"
  start=$(date +%s)
  S=$NAME OUT="$out" ROOTDIR=$5 "$sh" -c "$script" &
  pid=$!
  while [ ! -s "$out" ] && [ $t -lt $((secs*10)) ]; do sleep 0.1; t=$((t+1)); done
  if [ -s "$out" ]; then echo "[$label] capture returned after $(( $(date +%s)-start ))s: $(cat "$out")"; wait $pid
  else echo "[$label] capture STILL BLOCKED after ${secs}s (caller pid $pid)"; CAPTURE_PID=$pid; fi
}

echo; echo "### S1: lab provision inside a capture (new helper, $(bash --version|head -1))"
start=$(date +%s)
( r=$("$LAB" provision "$NAME" 2>&1; echo "provision rc=$?"); echo "$r" > "$SCR/prov.out" ) &
ppid_=$!; t=0
while [ ! -s "$SCR/prov.out" ] && [ $t -lt 300 ]; do sleep 0.1; t=$((t+1)); done
[ -s "$SCR/prov.out" ] && echo "[provision] capture returned after $(( $(date +%s)-start ))s: $(cat "$SCR/prov.out")" || echo "[provision] STILL BLOCKED after 30s"
server_report "$NAME"

ADAPTER_SCRIPT='
  . "$ROOTDIR/bin/backends/herdr.sh"
  outer() { fm_backend_herdr_server_ensure "$S"; }
  if [ "${SHAPE:-plain}" = redirected ]; then
    result=$(outer >/dev/null 2>&1; printf "returned rc=%s" $?)
  else
    result=$(fm_backend_herdr_server_ensure "$S"; printf "returned rc=%s" $?)
  fi
  printf "%s\n" "$result" > "$OUT"'

for variant in "S2 new /usr/bin/env-bash5 plain" "S3 new /bin/bash redirected"; do
  set -- $variant
  sh=$3; [ "$sh" = /usr/bin/env-bash5 ] && sh=$(command -v bash)
  echo; echo "### $1: stop lab server, restart via adapter fm_backend_herdr_server_ensure in a capture ($($sh --version|head -1), shape=$4)"
  "$LAB" stop "$NAME" >/dev/null; sleep 1; echo "after stop running: $("$LAB" run "$NAME" status --json 2>/dev/null | jq -r '.server.running')"
  if [ "$1" = S2 ]; then
    ln -sf "$(command -v herdr)" "$SCR/herdr-selected"
    export FM_BACKEND_HERDR_CLIENT_SESSION=$NAME FM_BACKEND_HERDR_BIN="$SCR/herdr-selected"
    export FM_HOME=/nonexistent/leaky-home CLAUDECODE=1 CURSOR_AGENT=1 FM_LIVE_MARK=kept
  fi
  SHAPE=$4 captured "$1" 20 "$sh" "$ADAPTER_SCRIPT" "$ROOT"
  unset FM_BACKEND_HERDR_CLIENT_SESSION FM_BACKEND_HERDR_BIN FM_HOME CLAUDECODE CURSOR_AGENT FM_LIVE_MARK
  server_report "$NAME"
done

echo; echo "### S4 (counterfactual): base-commit adapter, same plain capture"
"$LAB" stop "$NAME" >/dev/null; sleep 1
CAPTURE_PID=""
SHAPE=plain captured S4-base 12 "$(command -v bash)" "$ADAPTER_SCRIPT" "$BASE"
server_report "$NAME"
if [ -n "$CAPTURE_PID" ]; then
  echo "guarded lab stop to release the held pipe..."
  "$LAB" stop "$NAME" >/dev/null; t=0
  while [ ! -s "$SCR/S4-base.out" ] && [ $t -lt 100 ]; do sleep 0.1; t=$((t+1)); done
  echo "[S4-base] after server stop: $(cat "$SCR/S4-base.out" 2>/dev/null || echo still-blocked)"
  kill $CAPTURE_PID 2>/dev/null
fi

echo; echo "### S5 (counterfactual): base-commit lab helper provision in a capture"
NAME2=$("$LAB" name fdleakbase)
echo "lab session 2: $NAME2"
start=$(date +%s)
( r=$("$BASE/bin/fm-herdr-lab.sh" provision "$NAME2" 2>&1; echo "provision rc=$?"); echo "$r" > "$SCR/prov2.out" ) &
p2=$!; t=0
while [ ! -s "$SCR/prov2.out" ] && [ $t -lt 120 ]; do sleep 0.1; t=$((t+1)); done
[ -s "$SCR/prov2.out" ] && echo "[base provision] returned after $(( $(date +%s)-start ))s" || echo "[base provision] capture STILL BLOCKED after 12s"
server_report "$NAME2"
"$LAB" stop "$NAME2" >/dev/null; t=0
while [ ! -s "$SCR/prov2.out" ] && [ $t -lt 100 ]; do sleep 0.1; t=$((t+1)); done
echo "[base provision] after guarded stop: $(cat "$SCR/prov2.out" 2>/dev/null || echo still-blocked)"
kill $p2 2>/dev/null
