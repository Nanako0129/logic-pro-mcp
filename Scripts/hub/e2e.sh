#!/usr/bin/env bash
# End-to-end check of LogicProMCPHub with curl. Starts the hub on a free port with a temp log; never
# calls a tool that drives Logic. Phase A uses the real LogicProMCP child (initialize, tools/list,
# subscribe refcount, DELETE). Phase B uses Scripts/hub/fake-child.py for lifecycle paths the real
# child cannot show without Logic (routing, progress, cancel, idle stop, respawn, crash).
#
#   Scripts/hub/e2e.sh [bin-dir]      bin-dir defaults to .build/debug; KEEP_LOG=file copies the phase-A hub log there
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$(cd "${1:-$ROOT/.build/debug}" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/hub-e2e.XXXXXX")"
cd "$T"   # not the repo: the child must find manifest.json through the hub, not by walking up from its cwd
PIDS=()
FAIL=0
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAIL=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# post SESSION JSON [extra curl args...]  -> prints HTTP status; body in $T/body, headers in $T/head
post() {
  local sid="$1" data="$2"; shift 2
  curl -sS --max-time 30 -D "$T/head" -o "$T/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    ${sid:+-H "Mcp-Session-Id: $sid"} "$@" -d "$data" "$URL"
}
sid_of() { grep -i '^mcp-session-id:' "$T/head" | tr -d '\r' | awk '{print $2}'; }
init() { post "" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$1\",\"capabilities\":{},\"clientInfo\":{\"name\":\"e2e\",\"version\":\"0\"}}}" >/dev/null; sid_of; }
notify_init() { post "$1" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; }
stream() { curl -sN -H 'Accept: text/event-stream' -H "Mcp-Session-Id: $1" "$URL" >"$2" 2>/dev/null & PIDS+=("$!"); }
start_hub() { # port log extra-env...
  local port="$1" log="$2"; shift 2
  env LOGIC_PRO_MCP_HUB_PORT="$port" LOGIC_PRO_MCP_HUB_LOG="$log" "$@" "$BIN/LogicProMCPHub" >"$T/hub.out" 2>&1 &
  HUB=$!; PIDS+=("$HUB")
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && return 0; sleep 0.1; done
  echo "hub did not come up"; cat "$T/hub.out"; exit 1
}
count() { grep -c "$1" "$2" || true; }

echo "== Phase A: real child ($BIN/LogicProMCP)"
PORT=$(freeport); URL="http://127.0.0.1:$PORT/mcp"; LOG="$T/a.log"
start_hub "$PORT" "$LOG" LOGIC_PRO_MCP_HUB_CHILD="$BIN/LogicProMCP"

check "foreign Origin is rejected (403)" '[ "$(post "" "{}" -H "Origin: https://evil.example")" = 403 ]'
check "localhost Origin passes the Origin check (400: no session, not 403)" '[ "$(post "" "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}" -H "Origin: http://localhost:3000")" = 400 ]'
check "wrong path 404" '[ "$(curl -s -o /dev/null -w %{http_code} http://127.0.0.1:$PORT/other)" = 404 ]'
S1=$(init 2025-03-26); jget "$T/body" 'd["result"]["protocolVersion"]' >"$T/v1"
check "S1 gets a session id" '[ -n "$S1" ]'
check "S1 protocolVersion = client's (2025-03-26)" '[ "$(cat $T/v1)" = 2025-03-26 ]'
check "S1 initialize id echoed" '[ "$(jget $T/body "d[\"id\"]")" = 1 ]'
S2=$(init 2099-01-01)
check "S2 protocolVersion = server latest" '[ "$(jget $T/body "d[\"result\"][\"protocolVersion\"]")" = 2025-11-25 ]'
check "S1 != S2" '[ "$S1" != "$S2" ]'
check "notifications/initialized -> 202" '[ "$(notify_init "$S1")" = 202 ] && [ "$(notify_init "$S2")" = 202 ]'
check "no session header -> 400" '[ "$(post "" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")" = 400 ]'
check "unknown session -> 404" '[ "$(post "bogus" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")" = 404 ]'
# two tools/list concurrently, ids deliberately equal
R1=$(post "$S1" '{"jsonrpc":"2.0","id":42,"method":"tools/list"}'); cp "$T/body" "$T/b1"
R2=$(post "$S2" '{"jsonrpc":"2.0","id":42,"method":"tools/list"}'); cp "$T/body" "$T/b2"
check "tools/list S1 200 with tools, id 42" '[ "$R1" = 200 ] && [ "$(jget $T/b1 "d[\"id\"]")" = 42 ] && [ "$(jget $T/b1 "len(d[\"result\"][\"tools\"])")" -gt 0 ]'
check "tools/list S2 200 with tools, id 42" '[ "$R2" = 200 ] && [ "$(jget $T/b2 "d[\"id\"]")" = 42 ] && [ "$(jget $T/b2 "len(d[\"result\"][\"tools\"])")" -gt 0 ]'
check "GET without session header -> 400, unknown -> 404" '[ "$(curl -s -o /dev/null -w %{http_code} -H "Accept: text/event-stream" $URL)" = 400 ] && [ "$(curl -s -o /dev/null -w %{http_code} -H "Accept: text/event-stream" -H "Mcp-Session-Id: nope" $URL)" = 404 ]'
stream "$S1" "$T/a1.sse"; stream "$S2" "$T/a2.sse"
check "exactly one child process" '[ "$(pgrep -P $HUB | wc -l | tr -d " ")" = 1 ]'

URI="logic://transport/state"
RS1=$(post "$S1" "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"$URI\"}}"); cp "$T/body" "$T/s1"
RS2=$(post "$S2" "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"$URI\"}}"); cp "$T/body" "$T/s2"
check "both subscribes answered 200 with result" '[ "$RS1" = 200 ] && [ "$RS2" = 200 ] && jget $T/s1 "d[\"result\"]" >/dev/null && jget $T/s2 "d[\"result\"]" >/dev/null'
check "child saw ONE resources/subscribe" '[ "$(count "child <- resources/subscribe" "$LOG")" = 1 ]'
check "DELETE S1 -> 200" '[ "$(curl -s -o /dev/null -w %{http_code} -X DELETE -H "Mcp-Session-Id: $S1" $URL)" = 200 ]'
check "S1 is gone (404)" '[ "$(post "$S1" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")" = 404 ]'
check "DELETE S1 again -> 404" '[ "$(curl -s -o /dev/null -w %{http_code} -X DELETE -H "Mcp-Session-Id: $S1" $URL)" = 404 ]'
check "no unsubscribe yet (S2 still subscribed)" '[ "$(count "resources/unsubscribe" "$LOG")" = 0 ]'
check "S2 still works" '[ "$(post "$S2" "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\"}")" = 200 ]'
check "DELETE S2 -> 200, child told to unsubscribe once" '[ "$(curl -s -o /dev/null -w %{http_code} -X DELETE -H "Mcp-Session-Id: $S2" $URL)" = 200 ] && sleep 0.5 && [ "$(count "child <- resources/unsubscribe" "$LOG")" = 1 ]'
CHILD=$(pgrep -P "$HUB")
kill "$HUB"; wait "$HUB" 2>/dev/null || true
sleep 4
check "child exits with the hub" '! kill -0 "$CHILD" 2>/dev/null'

echo "== Phase B: fake child (lifecycle)"
PORT=$(freeport); URL="http://127.0.0.1:$PORT/mcp"; LOG="$T/b.log"; FLOG="$T/fake.log"; : >"$FLOG"
start_hub "$PORT" "$LOG" LOGIC_PRO_MCP_HUB_CHILD="$ROOT/Scripts/hub/fake-child.py" LOGIC_PRO_MCP_HUB_IDLE_SECONDS=3 FAKE_CHILD_LOG="$FLOG"
A=$(init 2025-06-18); B=$(init 2025-06-18)
notify_init "$A" >/dev/null; notify_init "$B" >/dev/null
stream "$A" "$T/bA.sse"; stream "$B" "$T/bB.sse"; sleep 0.3
post "$A" '{"jsonrpc":"2.0","id":1,"method":"resources/subscribe","params":{"uri":"u://x"}}' >/dev/null
post "$B" '{"jsonrpc":"2.0","id":1,"method":"resources/subscribe","params":{"uri":"u://y"}}' >/dev/null
post "$A" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"poke","arguments":{"uri":"u://x"}}}' >/dev/null
post "$A" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"poke_all"}}' >/dev/null
sleep 0.5
check "resources/updated(u://x) reaches only subscriber A" 'grep -q "resources/updated" "$T/bA.sse" && ! grep -q "resources/updated" "$T/bB.sse"'
check "list_changed reaches both streams" 'grep -q list_changed "$T/bA.sse" && grep -q list_changed "$T/bB.sse"'
check "one start, one init" '[ "$(count "^start" "$FLOG")" = 1 ] && [ "$(count "^initialized" "$FLOG")" = 1 ]'

# progress + cancel: A calls slow with its own token and id 77
post "$A" '{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"slow","_meta":{"progressToken":"my-token"}}}' >/dev/null & SLOW=$!
sleep 0.5
post "$A" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":77}}' >/dev/null
wait $SLOW || true
check "progress carries the client's original token, only on A's stream" 'grep -q "my-token" "$T/bA.sse" && ! grep -q "progress" "$T/bB.sse"'
check "cancel requestId rewritten to the id the child saw" '[ "$(grep "^request" "$FLOG" | tail -1 | cut -d" " -f2)" = "$(grep "^cancelled" "$FLOG" | tail -1 | cut -d" " -f2)" ] && [ "$(grep "^cancelled" "$FLOG" | tail -1 | cut -d" " -f2)" != 77 ]'

# idle stop (3 s), respawn with re-subscribe
sleep 5
check "child stopped after idle" '[ -z "$(pgrep -P $HUB || true)" ]'
R=$(post "$A" '{"jsonrpc":"2.0","id":8,"method":"tools/list"}')
check "next request respawns the child and succeeds" '[ "$R" = 200 ] && [ "$(count "^start" "$FLOG")" = 2 ]'
check "respawn re-subscribed both URIs" '[ "$(count "^subscribe u://x" "$FLOG")" = 2 ] && [ "$(count "^subscribe u://y" "$FLOG")" = 2 ]'

# crash: in-flight request gets a JSON-RPC error, next request respawns
R=$(post "$A" '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"die"}}')
check "request in flight when child dies -> JSON-RPC error" '[ "$R" = 200 ] && [ "$(jget $T/body "d[\"error\"][\"code\"]")" = -32603 ] && [ "$(jget $T/body "d[\"id\"]")" = 9 ]'
R=$(post "$A" '{"jsonrpc":"2.0","id":10,"method":"tools/list"}')
check "respawn after crash" '[ "$R" = 200 ] && [ "$(count "^start" "$FLOG")" = 3 ]'
kill "$HUB"; wait "$HUB" 2>/dev/null || true

echo
[ "$FAIL" = 0 ] && echo "ALL PASSED" || { echo "FAILURES (temp dir kept: $T)"; exit 1; }
[ -z "${KEEP_LOG:-}" ] || cp "$T/a.log" "$KEEP_LOG"
cd /; rm -rf "$T"
