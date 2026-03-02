#!/usr/bin/env bash

if [[ -z "${SOCKET_PATH:-}" ]]; then
  SOCKET_PATH=".pnevma/run/control.sock"
fi

pnevma_ctl() {
  local method="$1"
  local params="${2:-{}}"
  cargo run -p pnevma-app --bin pnevma -- ctl "$method" --socket "$SOCKET_PATH" --params-json "$params"
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
