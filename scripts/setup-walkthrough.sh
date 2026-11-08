#!/usr/bin/env bash
# S1b walkthrough (scripted): drive the four setup endpoints against a real
# `seal serve`, on a fresh SEAL_HOME, and record every status code + body.
set -u
HOME_DIR=/tmp/seal-walk
PORT=18090
BASE=http://127.0.0.1:$PORT

rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR/config"
cat > "$HOME_DIR/config/config.toml" <<EOF
[gateway]
port = $PORT
host = "127.0.0.1"
ws_port = 18091
EOF
# mode = "none" is the explicit operator waiver: it takes the passkey
# middleware out of the picture so this walkthrough can run from curl.
printf '[access_control]\nmode = "none"\n' > "$HOME_DIR/security.toml"
chmod 600 "$HOME_DIR/security.toml"

SEAL_HOME="$HOME_DIR" nix develop --command cabal run -v0 seal -- serve \
  > /tmp/walk-server.log 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; pkill -P $SERVER 2>/dev/null' EXIT

for _ in $(seq 1 120); do
  if curl -fsS "$BASE/api/health" > /dev/null 2>&1; then break; fi
  sleep 1
done

say() { printf '\n### %s\n' "$*"; }
show() { printf 'HTTP %s\n' "$(tail -n1 /tmp/walk-code)"; cat /tmp/walk-body; printf '\n'; }
call() { # method path [json]
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -sS -o /tmp/walk-body -w '%{http_code}' -X "$method" \
      -H 'Content-Type: application/json' -d "$body" "$BASE$path" > /tmp/walk-code
  else
    curl -sS -o /tmp/walk-body -w '%{http_code}' -X "$method" "$BASE$path" > /tmp/walk-code
  fi
}

say "1. GET /api/setup (empty install)"
call GET /api/setup; show

say "2. POST /api/setup/vault {\"backend\":\"local\"}  (real age-keygen)"
call POST /api/setup/vault '{"backend":"local"}'; show

say "3. GET /api/setup (vault step now ready)"
call GET /api/setup; show

say "4. POST /api/setup/vault {\"backend\":\"local\"} again (must be 409)"
call POST /api/setup/vault '{"backend":"local"}'; show

say "5. POST /api/providers {name:anthropic, api_key:placeholder}"
call POST /api/providers '{"name":"anthropic","api_key":"sk-ant-placeholder"}'; show

say "6. GET /api/setup (required_complete now true)"
call GET /api/setup; show

say "7. POST /api/providers/anthropic/test (a failed ping is still 200)"
call POST /api/providers/anthropic/test '{}'; show

say "8. POST /api/providers/nope/test (unknown provider: 400)"
call POST /api/providers/nope/test '{}'; show

say "9. POST /api/setup/vault/reopen (on_demand: already openable)"
call POST /api/setup/vault/reopen '{}'; show

say "10. POST /api/setup/vault with a relative identity (400)"
call POST /api/setup/vault '{"backend":"user","recipient":"age1qqq","identity_path":"rel/keys.txt"}'; show

say "11. POST /api/setup/vault with an evil Origin (403, nothing written)"
curl -sS -o /tmp/walk-body -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'Origin: https://evil.example' \
  -d '{"backend":"local"}' "$BASE/api/setup/vault" > /tmp/walk-code
show

say "12. GET /api/setup still reports the same recipient (no change from 11)"
call GET /api/setup; show

say "13. files written"
ls -l "$HOME_DIR/security.toml" "$HOME_DIR/config/vault/" "$HOME_DIR/keys/" 2>&1
say "security.toml contents (only the three vault fields + access_control)"
cat "$HOME_DIR/security.toml"
