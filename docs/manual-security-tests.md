# Manual Security Tests (G4-G10)

These tests require a running Pnevma app instance. All curl commands assume:

- `BASE_URL` — the HTTPS URL of the `pnevma-remote` server on the machine's Tailscale IP or MagicDNS name (for example `https://100.101.102.103:8443`)
- `WS_URL` — the matching WebSocket endpoint at `/api/ws`
- `TOKEN` — a valid bearer token obtained from `/api/auth/token`
- Self-signed TLS: use `-k` / `--insecure` with curl, or pass `--cacert <cert.pem>`
- Remote access only starts when Tailscale is available; `localhost` is not a supported bind target for `pnevma-remote`

## Local setup

1. Enable remote access in `pnevma.toml` and launch the app.
2. Discover the server address:

   ```bash
   TAILSCALE_IP="$(tailscale status --json | jq -r '.Self.TailscaleIPs[0]')"
   BASE_URL="https://${TAILSCALE_IP}:8443"
   WS_URL="wss://${TAILSCALE_IP}:8443/api/ws"
   ```

3. Mint a token with the configured remote password:

   ```bash
   TOKEN="$(
     curl -sk -X POST "$BASE_URL/api/auth/token" \
       -H "Content-Type: application/json" \
       -d '{"password":"<remote password>"}' \
       | jq -r '.token'
   )"
   ```

```bash
TAILSCALE_IP="$(tailscale status --json | jq -r '.Self.TailscaleIPs[0]')"
BASE_URL="https://${TAILSCALE_IP}:8443"
WS_URL="wss://${TAILSCALE_IP}:8443/api/ws"
TOKEN="<paste valid token here>"
```

---

## G4: Latency Validation

**Reference**: `docs/latency-validation.md`

**Procedure**:

1. Build a release app via Xcode: `Product → Archive`.
2. Open a project and create at least two panes (terminal + one non-terminal pane).
3. In the terminal pane, run:
   ```bash
   for i in {1..200}; do printf "ping-%03d\n" "$i"; done
   ```
4. While output is active, type continuously for 30 seconds and note perceived lag.
5. Run the proxy benchmark for supporting data:
   ```bash
   bash scripts/latency_proxy.sh
   ```

**Pass**: No sustained lag above 50 ms during typing.
**Fail**: Repeated perceived lag events exceeding the threshold.

---

## G5: Password Source Hardening

**Procedure**:

1. Create an insecure remote password file:

   ```bash
   mkdir -p "$HOME/.config/pnevma"
   printf 'test-password\n' > "$HOME/.config/pnevma/remote-password"
   chmod 0644 "$HOME/.config/pnevma/remote-password"
   ```

2. Start Pnevma with remote access enabled and no `PNEVMA_REMOTE_PASSWORD` env var or matching Keychain item.
3. Confirm remote startup fails closed with an error mentioning insecure password-file permissions.
4. Fix the mode and retry:

   ```bash
   chmod 0600 "$HOME/.config/pnevma/remote-password"
   ```

5. Configure socket password mode with a password file in `~/.config/pnevma/config.toml`, give that file mode `0644`, and verify the local control socket also refuses to start.
6. Change the socket password file to mode `0600` and verify the control socket starts successfully.

**Pass**: insecure password files are rejected and secure password files are accepted.
**Fail**: remote or socket auth starts with group/world-readable password files.

---

## G5b: Secret Redaction Regression

Verify that recognizable provider credentials are redacted before persistence and remote fan-out.

### G5b.1: Session output and scrollback

1. In a live terminal/session pane, print sample secrets:

   ```bash
   printf 'OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890\n'
   printf 'ANTHROPIC_API_KEY="sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890"\n'
   ```

2. Inspect session output in the app and confirm the raw token text is replaced with `[REDACTED]`.
3. Inspect the corresponding scrollback/timeline view and confirm the raw token text does not appear there either.

### G5b.2: Remote-visible output

1. With a valid remote token, subscribe to the session output stream or open the remote session view.
2. Repeat the sample output above.
3. Confirm the remote-visible payload contains `[REDACTED]` and does not expose the raw provider token.

**Pass**: raw provider tokens never appear in live output, persisted scrollback/timeline, or remote-visible session payloads.
**Fail**: any `sk-proj-...`, `sk-ant-...`, or env-assignment form appears unredacted after emission.

---

## G5c: Local Control Plane Security

### G5c.1: Socket auth mode verification

1. Configure `socket_auth_mode = "password"` in `~/.config/pnevma/config.toml` with a known password file (mode `0600`).
2. Connect via `socat` with no password:

   ```bash
   echo '{"id":"t1","method":"project.status","params":{}}' \
     | socat - UNIX-CONNECT:.pnevma/run/control.sock
   ```

   **Expected**: response contains `"code":"unauthorized"` and `"missing auth.password"`.

3. Connect with wrong password:

   ```bash
   echo '{"id":"t2","method":"project.status","params":{},"auth":{"password":"wrong"}}' \
     | socat - UNIX-CONNECT:.pnevma/run/control.sock
   ```

   **Expected**: response contains `"code":"unauthorized"` and `"invalid password"`.

4. Connect with correct password:

   ```bash
   echo '{"id":"t3","method":"project.status","params":{},"auth":{"password":"<correct>"}}' \
     | socat - UNIX-CONNECT:.pnevma/run/control.sock
   ```

   **Expected**: `"ok":true`.

5. Attempt a privileged command (`session.new`) in password mode:

   ```bash
   echo '{"id":"t4","method":"session.new","params":{"name":"x","cwd":".","command":"zsh"},"auth":{"password":"<correct>"}}' \
     | socat - UNIX-CONNECT:.pnevma/run/control.sock
   ```

   **Expected**: response contains `"code":"unauthorized"` and `"privileged"`.

**Pass**: missing/wrong passwords rejected, correct password accepted, privileged commands blocked in password mode.

### G5c.2: Socket rate limiting

1. Set `socket_rate_limit_rpm = 3` in the project's `pnevma.toml`.
2. Send a burst of 5 requests over the same connection:

   ```bash
   for i in $(seq 1 5); do
     echo "{\"id\":\"r$i\",\"method\":\"project.status\",\"params\":{}}"
   done | socat - UNIX-CONNECT:.pnevma/run/control.sock
   ```

3. Verify that the first 3 responses have `"ok":true` and the remaining responses contain `"code":"rate_limited"`.
4. Check application logs for `control plane rate limit exceeded` warning with `peer_uid`.

**Pass**: requests beyond the RPM limit are rejected with `rate_limited`.

### G5c.3: Audit trail inspection

1. After running G5c.1 and G5c.2, open the project's SQLite database and query:

   ```sql
   SELECT event_type, payload_json FROM events
   WHERE event_type LIKE 'Automation%'
   ORDER BY created_at DESC LIMIT 20;
   ```

2. Verify:
   - `AutomationRequestReceived` and `AutomationRequestFailed` payloads contain `"peer_uid"` and `"auth_mode"` keys.
   - `AutomationAuthThresholdExceeded` event is present after 5 repeated auth failures in G5c.1 step 3 (repeat 5 times).
   - No raw passwords appear in any `payload_json` value.

**Pass**: all audit payloads include `peer_uid` and `auth_mode`; threshold event fires after repeated failures; no secrets in DB.
**Fail**: missing `peer_uid`/`auth_mode` in payloads, missing threshold event, or raw password in any payload.

---

## G6: Signed Release Artifact Validation

**Reference**: `scripts/release-macos-sign.sh`, `scripts/release-macos-package-dmg.sh`, `docs/macos-release.md`

**Procedure**:

```bash
# 1. Sign app
APP_PATH=/path/to/Pnevma.app bash scripts/release-macos-sign.sh

# 2. Package DMG
APP_PATH=/path/to/Pnevma.app DMG_PATH=/path/to/Pnevma.dmg \
  bash scripts/release-macos-package-dmg.sh

# 3. Sign DMG
TARGET_PATH=/path/to/Pnevma.dmg bash scripts/release-macos-sign.sh

# 4. Verify codesign
codesign --verify --deep --strict /path/to/Pnevma.app && echo "PASS" || echo "FAIL"
codesign --verify --verbose=2 /path/to/Pnevma.dmg && echo "PASS" || echo "FAIL"

# 5. Optional informational Gatekeeper output
spctl --assess --type open --context context:primary-signature --verbose=4 /path/to/Pnevma.dmg || true
```

For the first public signed-only DMG, notarization and stapling are intentionally
deferred. `spctl` output is still useful to capture, but the release criterion
for this cut is the documented Finder `Open` or `Open Anyway` flow on a clean
machine rather than Gatekeeper acceptance.

**Pass**: signing and packaging succeed, `codesign` verifies both artifacts, and the documented first-launch flow works on a clean machine.
**Fail**: any signing or packaging step exits non-zero, `codesign` fails, or the app only launches through undocumented bypass steps.

---

## G7: Auth Bypass Testing

Tests that the API correctly rejects unauthenticated and malformed requests.

**Automated coverage:** `middleware_rejects_missing_token`, `middleware_rejects_wrong_token`, `middleware_rejects_expired_token`, `middleware_rejects_revoked_token`, `middleware_rejects_query_token_on_non_ws` (unit tests in `auth_token.rs`); `session_input_denied_when_config_disabled`, `session_input_denied_without_subscription`, `session_input_denied_for_readonly_role` (integration tests in `ws_event_flow.rs`).

### G7a: No token

```bash
curl -sk "$BASE_URL/api/tasks" | jq .
```

**Expected**: HTTP 401 `{"error":"unauthorized"}` or equivalent.
**Pass**: Status code 401.

### G7b: Expired token

Obtain a token, wait for it to expire (default TTL: see `config.token_ttl_hours`), then:

```bash
curl -sk -H "Authorization: Bearer $EXPIRED_TOKEN" "$BASE_URL/api/tasks" | jq .
```

**Expected**: HTTP 401.

For faster testing, issue a token and immediately revoke it:

```bash
curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/auth/token" | jq .
curl -sk -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/tasks" | jq .
```

**Pass**: Second request returns 401 after revocation.

### G7c: Malformed token

```bash
curl -sk -H "Authorization: Bearer not-a-valid-token" "$BASE_URL/api/tasks" | jq .
curl -sk -H "Authorization: Bearer " "$BASE_URL/api/tasks" | jq .
curl -sk -H "Authorization: notbearer $TOKEN" "$BASE_URL/api/tasks" | jq .
```

**Expected**: HTTP 401 for all three.

### G7d: Query-string token on non-WebSocket endpoint

```bash
curl -sk "$BASE_URL/api/tasks?token=$TOKEN" | jq .
```

**Expected**: HTTP 401 (query-string `?token=` only accepted for WS upgrade).
**Pass**: Status 401.

### G7e: Auth audit telemetry

1. Mint a token as shown in Local setup.
2. Make one authenticated request:

   ```bash
   curl -sk -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/tasks" >/dev/null
   ```

3. Revoke the token:

   ```bash
   curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/auth/token" | jq .
   ```

4. Inspect the remote server logs and confirm they include `auth_event`, `subject`, and `token_id`.
5. Confirm the logs do not include the raw password or bearer token value.

**Pass**: audit logs record token issuance/use/revocation with `subject` and safe `token_id`, and no raw credential material.
**Fail**: subjectless auth logs or any raw token/password in logs.

---

## G8: Rate Limit Burst Testing

**Automated coverage:** `ws_per_ip_connection_cap_enforced`, `ws_message_rate_burst_triggers_error` (integration tests in `ws_event_flow.rs`); `rate_limit_state_exhausts_at_threshold`, `rate_limit_state_creates_per_ip_limiter`, `same_ip_returns_same_limiter_instance` (unit tests in `rate_limit.rs`).

### G8a: API rate limit (default: 60 req/min)

```bash
# Send 65 requests in rapid succession — expect 429 after 60
for i in $(seq 1 65); do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/tasks")
  echo "Request $i: $STATUS"
done
```

**Expected**: First 60 requests return 200; requests 61+ return 429.
**Pass**: 429 is returned at or before request 61.

### G8b: Auth rate limit (default: 5 req/min)

```bash
# Send 7 auth requests — expect 429 after 5
for i in $(seq 1 7); do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/api/auth/token" \
    -H "Content-Type: application/json" \
    -d '{"password":"wrong"}')
  echo "Auth attempt $i: $STATUS"
done
```

**Expected**: First 5 requests return 401 (wrong password); requests 6-7 return 429.
**Pass**: 429 appears at or before request 6.

---

## G9: RPC Allowlist Testing

Verify that methods not in `ALLOWED_RPC_METHODS` are blocked on the generic RPC endpoint.

**Automated coverage:** `ws_rpc_rejects_blocked_methods`, `ws_rpc_allows_safe_methods` (unit tests in `ws.rs`); `ws_rpc_rejects_operator_method_for_readonly` (integration test in `ws_event_flow.rs`).

### G9a: Blocked method via RPC endpoint

```bash
# session.new is explicitly excluded from the allowlist
curl -sk -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id":"test-1","method":"session.new","params":{"name":"x","cwd":".","command":"zsh"}}' \
  "$BASE_URL/api/rpc" | jq .
```

**Expected**: HTTP 403 or error response with `method_not_allowed`.

### G9b: Blocked method via WebSocket

Connect via WebSocket and send an RPC message for a blocked method:

```bash
# Using websocat (install via brew install websocat)
echo '{"type":"Rpc","id":"test-1","method":"session.new","params":{"name":"x","cwd":".","command":"zsh"}}' \
  | websocat --header "Authorization: Bearer $TOKEN" \
    "$WS_URL" -k
```

**Expected**: Response contains `method_not_allowed` error.

### G9c: Allowed method works

```bash
curl -sk -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id":"test-2","method":"task.list","params":{}}' \
  "$BASE_URL/api/rpc" | jq .
```

**Expected**: HTTP 200 with `ok: true` and task list in result.

---

## G10: Body and WebSocket Size Limit Testing

**Automated coverage:** `MAX_WS_MESSAGE_SIZE` (64 KB) is enforced by axum's `WebSocketUpgrade::max_message_size` in `ws_handler`. `RequestBodyLimitLayer` (2 MB) is applied in the server router builder.

### G10a: Oversized REST body (limit: 2 MB)

```bash
# Generate a 10 MB payload
python3 -c "import sys; sys.stdout.write('x' * 10_000_000)" > /tmp/big-body.txt

curl -sk -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/big-body.txt \
  "$BASE_URL/api/tasks" | jq .
```

**Expected**: HTTP 413 (Payload Too Large).
**Pass**: Status 413; body not processed.

### G10b: Oversized WebSocket message (limit: 64 KB)

```bash
# Generate a 1 MB WS message
python3 -c "
import sys
payload = 'x' * 1_000_000
msg = '{\"type\":\"Rpc\",\"id\":\"big-1\",\"method\":\"task.list\",\"params\":{\"padding\":\"' + payload + '\"}}'
print(msg)
" | websocat --header "Authorization: Bearer $TOKEN" "$WS_URL" -k
```

**Expected**: Connection closed by server with close code 1009 (message too big), or the message is dropped and an error response is returned.
**Pass**: Server does not process the oversized message; connection may be dropped.

### G10c: Edge-case: exactly 2 MB body (should succeed if valid JSON)

```bash
# 2 MB - 1 byte payload (within limit)
python3 -c "
import json
# Fill a string field to get close to 2 MB total
padding = 'x' * (2_097_100)
print(json.dumps({'title': 'test', 'goal': padding, 'priority': 'P2', 'acceptance_criteria': []}))
" | curl -sk -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  "$BASE_URL/api/tasks" | jq '{ok: .ok, error: .error}'
```

**Expected**: Either 200 (accepted) or 400 (invalid params), but NOT 413.

---

## Notes

- All tests require a running Pnevma app with `pnevma-remote` enabled on a Tailscale address and a valid TLS certificate.
- The `rate_limit_rpm` default is 60; `auth` limit is hardcoded to 5. Both can be configured in `pnevma.toml`.
- For WebSocket tests, install `websocat`: `brew install websocat`.
- For rate-limit tests, use a fresh IP or restart the app between `G8a` and `G8b` to reset limiters.
