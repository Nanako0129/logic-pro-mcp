#!/usr/bin/env python3
"""Minimal stdio MCP server used only by Scripts/hub/e2e.sh to exercise hub lifecycle paths
(idle stop, respawn, crash, progress, cancel, notification routing) without Logic Pro."""
import json, os, sys, threading, time

LOG = os.environ["FAKE_CHILD_LOG"]
lock = threading.Lock()


def log(s):
    with open(LOG, "a") as f:
        f.write(s + "\n")


def out(o):
    with lock:
        sys.stdout.write(json.dumps(o) + "\n")
        sys.stdout.flush()


def slow(mid, token):
    if token is not None:
        out({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": 1}})
    time.sleep(1.5)
    out({"jsonrpc": "2.0", "id": mid, "result": {"content": []}})


log("start")
for line in sys.stdin:
    m = json.loads(line)
    method, mid, params = m.get("method"), m.get("id"), m.get("params") or {}
    if method == "initialize":
        out({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-11-25", "capabilities": {"resources": {"subscribe": True}, "tools": {}},
            "serverInfo": {"name": "fake", "version": "0"}}})
    elif method == "notifications/initialized":
        log("initialized")
    elif method == "notifications/cancelled":
        log("cancelled %s" % params.get("requestId"))
    elif method in ("resources/subscribe", "resources/unsubscribe"):
        log("%s %s" % (method.split("/")[1], params.get("uri")))
        out({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif method == "tools/list":
        out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "poke", "inputSchema": {"type": "object"}}]}})
    elif method == "tools/call":
        name = params.get("name")
        if name == "poke":
            out({"jsonrpc": "2.0", "method": "notifications/resources/updated", "params": {"uri": params["arguments"]["uri"]}})
            out({"jsonrpc": "2.0", "id": mid, "result": {"content": []}})
        elif name == "poke_all":
            out({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
            out({"jsonrpc": "2.0", "id": mid, "result": {"content": []}})
        elif name == "slow":
            log("request %s" % mid)
            threading.Thread(target=slow, args=(mid, (params.get("_meta") or {}).get("progressToken"))).start()
        elif name == "die":
            os._exit(1)
