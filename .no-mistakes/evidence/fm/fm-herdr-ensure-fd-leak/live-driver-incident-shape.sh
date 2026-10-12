#!/usr/bin/env bash
# Incident shape: caller captures $(...) around a redirected function that restarts the server.
set -u
ROOT=$1; BASE=$2; SCR=$3
LAB="$ROOT/bin/fm-herdr-lab.sh"
NAME=$("$LAB" name fdshape); NAME2=""
DEFAULT_BEFORE=$(herdr session list --json | jq -c '[.sessions[]|select(.default)|{name,running,socket_path}]')
cleanup() {
  for n in $NAME2 $NAME; do echo "## teardown $n"; "$LAB" teardown "$n"; echo "teardown rc=$?"; done
  DEFAULT_AFTER=$(herdr session list --json | jq -c '[.sessions[]|select(.default)|{name,running,socket_path}]')
  echo "default before: $DEFAULT_BEFORE"; echo "default after:  $DEFAULT_AFTER"
  [ "$DEFAULT_BEFORE" = "$DEFAULT_AFTER" ] && echo "DEFAULT SESSION UNCHANGED" || echo "DEFAULT SESSION CHANGED!"
  herdr session list --json | jq -c '[.sessions[].name]'
}
trap cleanup EXIT
report() { # <session>
  local pid ppid
  echo "  running: $("$LAB" run "$1" status --json 2>/dev/null | jq -r '.server.running')"
  pid=$(pgrep -f "server --session $1\$" | head -1); [ -n "$pid" ] || { echo "  no server"; return; }
  ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  echo "  server pid=$pid parent=$ppid ($(ps -o comm= -p "$ppid"))"
  echo "  server pipe fds:"; lsof -p "$pid" -a -d 3-255 2>/dev/null | awk 'NR>1 && /PIPE/ {print "    fd "$4" "$5" "$6" "$NF}'
  if [ "$ppid" != 1 ]; then echo "  wrapper parent pipe fds:"; lsof -p "$ppid" -a -d 3-255 2>/dev/null | awk 'NR>1 && /PIPE/ {print "    fd "$4" "$5" "$6" "$NF}'; fi
}
wait_out() { # <file> <secs> -> 0 if produced
  local t=0; while [ ! -s "$1" ] && [ $t -lt $(($2*10)) ]; do sleep 0.1; t=$((t+1)); done; [ -s "$1" ]
}
SCRIPT='
  . "$ROOTDIR/bin/backends/herdr.sh"
  restart_quietly() { fm_backend_herdr_server_ensure "$S"; }
  result=$(restart_quietly >/dev/null 2>&1; printf "returned rc=%s" $?)
  printf "%s\n" "$result" > "$OUT"'
"$LAB" provision "$NAME" >/dev/null || exit 1
echo "lab session: $NAME"
for v in "new $ROOT $(command -v bash)" "new $ROOT /bin/bash" "base $BASE $(command -v bash)" "base $BASE /bin/bash"; do
  set -- $v; which=$1; dir=$2; sh=$3
  case "$sh" in /bin/bash) tag=bash32 ;; *) tag=bash5 ;; esac; out="$SCR/$which-$tag.out"; rm -f "$out"; t0=$(date +%s)
  echo; echo "### adapter=$which bash=$($sh --version | head -1 | sed 's/GNU bash, version //')"
  "$LAB" stop "$NAME" >/dev/null; sleep 1
  S=$NAME OUT=$out ROOTDIR=$dir "$sh" -c "$SCRIPT" & cpid=$!
  if wait_out "$out" 15; then echo "  CAPTURE RETURNED in $(( $(date +%s)-t0 ))s: $(cat "$out")"; wait $cpid
  else
    echo "  CAPTURE BLOCKED after 15s (server already up below)"; report "$NAME"
    echo "  guarded lab stop..."; "$LAB" stop "$NAME" >/dev/null
    wait_out "$out" 10 && echo "  capture released only after server stop: $(cat "$out")" || { echo "  still blocked; killing"; kill $cpid; }
    continue
  fi
  report "$NAME"
done

echo; echo "### lab helper fm_herdr_lab_provision sourced in-process, inside a redirected function inside a capture"
for v in "new $(command -v bash)" "new /bin/bash" "base $(command -v bash)" "base /bin/bash"; do
  set -- $v; which=$1; sh=$2; case "$sh" in /bin/bash) tag=bash32 ;; *) tag=bash5 ;; esac
  NAME2=$("$LAB" name "p$which$tag"); out="$SCR/prov-$which-$tag.out"; rm -f "$out"
  dir=$ROOT; [ $which = base ] && dir=$BASE
  echo "-- helper=$which $tag session=$NAME2"; t0=$(date +%s)
  N=$NAME2 OUT=$out D=$dir "$sh" -c '. "$D/bin/fm-herdr-lab.sh"; prov() { fm_herdr_lab_provision "$N"; }; r=$(prov >/dev/null 2>&1; echo "rc=$?"); echo "$r" > "$OUT"' & cpid=$!
  if wait_out "$out" 15; then echo "  CAPTURE RETURNED in $(( $(date +%s)-t0 ))s: $(cat "$out")"; wait $cpid; report "$NAME2"
  else echo "  CAPTURE BLOCKED after 15s"; report "$NAME2"; "$LAB" stop "$NAME2" >/dev/null
    wait_out "$out" 10 && echo "  released only after guarded server stop: $(cat "$out")" || { echo "  still blocked; killing"; kill $cpid; }; fi
  echo "## teardown $NAME2"; "$LAB" teardown "$NAME2"; echo "teardown rc=$?"; NAME2=""
done
