#!/usr/bin/env bash

if [[ -z "${SOCKET_PATH:-}" ]]; then
  SOCKET_PATH=".pnevma/run/control.sock"
fi

# Send a JSON-RPC control request over the Unix socket and print the response.
# Protocol: newline-delimited JSON — send one line, receive one line.
# Requires: Python 3 (standard on macOS) or socat.
pnevma_ctl() {
  local method="$1"
  local params
  params="${2:-}"
  if [[ -z "$params" ]]; then params="{}"; fi
  local id
  id="req-$(date +%s%N 2>/dev/null || echo $$)"
  local request
  request="$(python3 -c "import json,sys; print(json.dumps({'id': sys.argv[1], 'method': sys.argv[2], 'params': json.loads(sys.argv[3])}))" "$id" "$method" "$params")"
  python3 - "$SOCKET_PATH" "$request" <<'EOF'
import socket, sys, json

sock_path = sys.argv[1]
request   = sys.argv[2]

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sock_path)
except OSError as e:
    sys.stderr.write("pnevma_ctl: connection failed: {}\n".format(e))
    sys.exit(1)

s.sendall((request + "\n").encode())

buf = b""
while b"\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
s.close()

line = buf.split(b"\n")[0].decode()
print(line)

try:
    resp = json.loads(line)
    sys.exit(0 if resp.get("ok") else 1)
except Exception:
    sys.exit(1)
EOF
}

json_extract() {
  local raw_json="$1"
  local expression="$2"
  node -e '
const payload = JSON.parse(process.argv[1]);
const expr = process.argv[2];
const parts = expr.split(".").filter(Boolean);
let cur = payload;
for (const part of parts) {
  if (cur === null || cur === undefined || !(part in cur)) {
    process.exit(2);
  }
  cur = cur[part];
}
if (typeof cur === "object") {
  process.stdout.write(JSON.stringify(cur));
} else {
  process.stdout.write(String(cur));
}
' "$raw_json" "$expression"
}
