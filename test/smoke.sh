#!/usr/bin/env bash
# =============================================================================
#  smoke.sh – backend + API smoke test (runs on any Linux, no Proxmox needed)
#
#  Starts the FastAPI backend against a temporary download directory and the
#  built React bundle, then exercises auth, files, uploads, downloads, jobs and
#  path-traversal protection with real HTTP requests.
#
#  Usage: bash test/smoke.sh
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${PDB_TEST_VENV:-/tmp/pdb-smoke-venv}"
PORT="${PDB_TEST_PORT:-8099}"
SRC_PORT="${PDB_TEST_SRC_PORT:-8098}"
WORK="$(mktemp -d /tmp/pdb-smoke.XXXXXX)"
DL="$WORK/downloads"
SRC="$WORK/source"
PASS="smoke-test-password"
COOKIE="$WORK/cookies.txt"
APP_PID=""
SRC_PID=""
FAILS=0

if [[ -t 1 ]]; then
  G=$'\033[1;32m'; R=$'\033[1;31m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; B=""; N=""
fi

pass() { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
fail() { printf '%s  xx%s %s\n' "$R" "$N" "$*"; FAILS=$((FAILS + 1)); }
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }

cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$SRC_PID" ]] && kill "$SRC_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- prerequisites -----------------------------------------------------------
command -v curl >/dev/null || { echo "curl fehlt"; exit 1; }
command -v jq >/dev/null || { echo "jq fehlt"; exit 1; }
[[ -f "$ROOT/app/frontend/dist/index.html" ]] || {
  echo "Frontend-Build fehlt: $ROOT/app/frontend/dist (npm run build)"; exit 1
}

step "Test-venv vorbereiten"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install -q -r "$ROOT/app/backend/requirements.txt"
pass "Abhängigkeiten installiert"

mkdir -p "$DL" "$SRC"
head -c 1048576 /dev/urandom >"$SRC/sample.bin"
printf 'hello from the proton download box\n' >"$SRC/note.txt"

step "Backend starten (Port $PORT)"
PDB_PORT="$PORT" \
PDB_PASSWORD="$PASS" \
PDB_SECRET="smoke-secret" \
PDB_DOWNLOAD_DIR="$DL" \
PDB_WEB_DIR="$ROOT/app/frontend/dist" \
PDB_LOG_LEVEL="warning" \
  "$VENV/bin/python" "$ROOT/app/backend/main.py" >"$WORK/app.log" 2>&1 &
APP_PID=$!

python3 -m http.server "$SRC_PORT" --bind 127.0.0.1 --directory "$SRC" \
  >"$WORK/src.log" 2>&1 &
SRC_PID=$!

ready=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
if [[ $ready -eq 1 ]]; then
  pass "Backend erreichbar"
else
  fail "Backend startet nicht"
  tail -n 40 "$WORK/app.log"
  exit 1
fi

BASE="http://127.0.0.1:$PORT"
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }

step "Health + Auth"
[[ "$(code "$BASE/api/health")" == "200" ]] && pass "GET /api/health → 200" || fail "health"
[[ "$(jq -r .status <"$WORK/body")" == "ok" ]] && pass "health.status = ok" || fail "health payload"

[[ "$(code "$BASE/api/status")" == "401" ]] && pass "GET /api/status ohne Login → 401" || fail "unauth status"

[[ "$(code -X POST -H 'Content-Type: application/json' -d '{"password":"wrong"}' "$BASE/api/login")" == "401" ]] \
  && pass "falsches Passwort → 401" || fail "wrong password"

[[ "$(code -c "$COOKIE" -X POST -H 'Content-Type: application/json' -d "{\"password\":\"$PASS\"}" "$BASE/api/login")" == "200" ]] \
  && pass "Login → 200 + Cookie" || fail "login"
grep -q pdb_session "$COOKIE" && pass "Session-Cookie gesetzt" || fail "cookie missing"

[[ "$(code -b "$COOKIE" "$BASE/api/status")" == "200" ]] && pass "GET /api/status mit Login → 200" || fail "auth status"
[[ "$(jq -r .app <"$WORK/body")" == "proton-download-box" ]] && pass "status.app korrekt" || fail "status.app"
[[ "$(jq -r '.services.web' <"$WORK/body")" == "true" ]] && pass "Service-Flags vorhanden" || fail "services"

step "Dateimanager"
[[ "$(code -b "$COOKIE" "$BASE/api/files")" == "200" ]] && pass "GET /api/files → 200" || fail "files"
[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' -d '{"path":"","name":"sub"}' "$BASE/api/files/mkdir")" == "200" ]] \
  && pass "Ordner anlegen → 200" || fail "mkdir"
[[ -d "$DL/sub" ]] && pass "Ordner existiert auf der Platte" || fail "mkdir on disk"

printf 'uploaded payload\n' >"$WORK/upload.txt"
[[ "$(code -b "$COOKIE" -F "path=sub" -F "file=@$WORK/upload.txt" "$BASE/api/files/upload")" == "200" ]] \
  && pass "Upload → 200" || fail "upload"
[[ -f "$DL/sub/upload.txt" ]] && pass "Upload liegt in /sub" || fail "upload on disk"

[[ "$(code -b "$COOKIE" "$BASE/api/files/download?path=sub/upload.txt")" == "200" ]] \
  && pass "Download → 200" || fail "download"
cmp -s "$WORK/body" "$WORK/upload.txt" && pass "Download-Inhalt identisch" || fail "download content"

[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' -d '{"path":"sub/upload.txt","name":"renamed.txt"}' "$BASE/api/files/rename")" == "200" ]] \
  && pass "Umbenennen → 200" || fail "rename"
[[ -f "$DL/sub/renamed.txt" ]] && pass "Datei umbenannt" || fail "rename on disk"

[[ "$(code -b "$COOKIE" "$BASE/api/files?path=../../etc")" == "400" ]] \
  && pass "Path-Traversal abgelehnt (400)" || fail "traversal not blocked"
[[ "$(code -b "$COOKIE" "$BASE/api/files/download?path=../../etc/passwd")" == "400" ]] \
  && pass "Traversal-Download abgelehnt (400)" || fail "traversal download"

step "Download-Job"
[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' \
  -d "{\"url\":\"http://127.0.0.1:$SRC_PORT/sample.bin\"}" "$BASE/api/jobs")" == "200" ]] \
  && pass "Job angelegt → 200" || fail "create job"
JOB_ID=$(jq -r .id <"$WORK/body")
[[ -n "$JOB_ID" && "$JOB_ID" != "null" ]] && pass "Job-ID: $JOB_ID" || fail "job id"

JOB_STATUS=""
for _ in $(seq 1 40); do
  JOB_STATUS=$(curl -s -b "$COOKIE" "$BASE/api/jobs" | jq -r ".jobs[] | select(.id==\"$JOB_ID\") | .status")
  [[ "$JOB_STATUS" == "done" || "$JOB_STATUS" == "error" ]] && break
  sleep 0.5
done
[[ "$JOB_STATUS" == "done" ]] && pass "Job abgeschlossen (done)" || fail "job status: $JOB_STATUS"
[[ -f "$DL/sample.bin" ]] && pass "Datei heruntergeladen" || fail "downloaded file missing"
[[ "$(stat -c %s "$DL/sample.bin" 2>/dev/null || echo 0)" == "1048576" ]] \
  && pass "Dateigröße 1 MiB korrekt" || fail "downloaded size"

[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' \
  -d '{"url":"file:///etc/passwd"}' "$BASE/api/jobs")" == "400" ]] \
  && pass "file://-URL abgelehnt (400)" || fail "scheme not blocked"

step "Aufräumen der API"
[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' -d '{"path":"sub","recursive":true}' "$BASE/api/files/delete")" == "200" ]] \
  && pass "Ordner rekursiv löschen → 200" || fail "delete dir"
[[ ! -d "$DL/sub" ]] && pass "Ordner entfernt" || fail "dir still exists"
[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' -d '{"path":"","recursive":true}' "$BASE/api/files/delete")" == "400" ]] \
  && pass "Root-Löschung abgelehnt (400)" || fail "root delete not blocked"

step "VPN-Steuerung"
[[ "$(code -b "$COOKIE" "$BASE/api/vpn")" == "200" ]] && pass "GET /api/vpn → 200" || fail "vpn options"
[[ "$(jq -r '.countries | length' <"$WORK/body")" -ge 3 ]] && pass "Länderliste vorhanden" || fail "countries"
[[ "$(code -b "$COOKIE" "$BASE/api/vpn/leaktest")" == "200" ]] && pass "Leak-Test → 200" || fail "leaktest"
[[ "$(jq -r '.checks | length' <"$WORK/body")" -ge 5 ]] && pass "Leak-Test liefert Checks" || fail "leak checks"
[[ "$(jq -r '.summary' <"$WORK/body")" != "null" ]] && pass "Leak-Test liefert Summary" || fail "leak summary"
[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' -d '{"country":"XYZ"}' "$BASE/api/vpn/connect")" == "400" ]] \
  && pass "ungültiger Ländercode → 400" || fail "country validation"
[[ "$(code -b "$COOKIE" "$BASE/api/vpn")" == "200" ]] && pass "VPN-Status abrufbar" || fail "vpn status"
[[ "$(code -b "$COOKIE" -X POST -H 'Content-Type: application/json' -d '{"enabled":true}' "$BASE/api/vpn/killswitch")" != "401" ]] \
  && pass "Killswitch-Endpunkt antwortet" || fail "killswitch endpoint"

step "SPA + Logout"
[[ "$(code "$BASE/")" == "200" ]] && pass "GET / liefert SPA" || fail "spa"
grep -q '<div id="root">' "$WORK/body" && pass "SPA-HTML enthält #root" || fail "spa html"
[[ "$(code "$BASE/api/does-not-exist")" == "404" ]] && pass "unbekannte API → 404" || fail "api 404"

[[ "$(code -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/api/logout")" == "200" ]] && pass "Logout → 200" || fail "logout"
[[ "$(code -b "$COOKIE" "$BASE/api/status")" == "401" ]] && pass "Nach Logout → 401" || fail "logout ineffective"

printf '\n'
if [[ $FAILS -eq 0 ]]; then
  printf '%s%s SMOKE TEST PASSED%s\n' "$G" "$B" "$N"
  exit 0
fi
printf '%s%s SMOKE TEST FAILED (%d)%s\n' "$R" "$B" "$FAILS" "$N"
printf '\n--- backend log ---\n'
tail -n 60 "$WORK/app.log"
exit 1
