#!/usr/bin/env bash
# =============================================================================
#  installer.sh – Host-Installer-Test ohne echten Proxmox-Host
#
#  Simuliert pct/pveam/pvesm mit Stubs und prüft Argumentparsing, Validierung,
#  nächste freie ID, Update-Erkennung und fremde Container (dry-run).
#
#  Usage: bash test/installer.sh
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/pdb-installer-test.XXXXXX)"
STUB="$WORK/bin"
STATE="$WORK/state"
FAILS=0

G=$'\033[1;32m'; R=$'\033[1;31m'; B=$'\033[1m'; N=$'\033[0m'
pass() { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
fail() { printf '%s  xx%s %s\n' "$R" "$N" "$*"; FAILS=$((FAILS + 1)); }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$STUB" "$STATE"

# --- stub: pct ---------------------------------------------------------------
cat >"$STUB/pct" <<'STUBEOF'
#!/usr/bin/env bash
state="${PDB_TEST_STATE:?}"
cmd="$1"; shift || true
case "$cmd" in
  config)
    id="${1:-}"
    if [[ -f "$state/foreign-$id" ]]; then
      echo "hostname: something-else"
      exit 0
    fi
    if [[ -f "$state/ct-$id" ]]; then
      echo "hostname: proton-download-box"
      echo "description: proton-download-box: test"
      exit 0
    fi
    exit 1
    ;;
  status)
    id="${1:-}"
    [[ -f "$state/ct-$id" ]] || exit 1
    echo "status: running"
    ;;
  exec)
    id="${1:-}"; shift
    [[ -f "$state/ct-$id" ]] || exit 1
    args="$*"
    case "$args" in
      *"test -f /etc/proton-download-box.env"*) exit 0 ;;
      *"sed -n"*"PDB_PASSWORD"*) echo "stub-web-pass" ;;
      *"sed -n"*"RDP_PASSWORD"*) echo "stub-rdp-pass" ;;
    esac
    exit 0
    ;;
  create)
    id="${1:-}"
    : >"$state/ct-$id"
    exit 0
    ;;
  *) exit 0 ;;
esac
STUBEOF

# --- stub: pvesm -------------------------------------------------------------
cat >"$STUB/pvesm" <<'STUBEOF'
#!/usr/bin/env bash
cmd="$1"; shift || true
case "$cmd" in
  status)
    content=""; storage=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -content) content="$2"; shift 2 ;;
        -storage) storage="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -n "$storage" ]]; then
      [[ "$storage" == "local" ]] && exit 0 || exit 1
    fi
    printf 'Name             Type     Status    Total     Used   Available\n'
    printf 'local             dir    active       100        1           99\n'
    printf 'local-lvm      lvmthin    active       100        1           99\n'
    ;;
  *) exit 0 ;;
esac
STUBEOF

# --- stub: pveam -------------------------------------------------------------
cat >"$STUB/pveam" <<'STUBEOF'
#!/usr/bin/env bash
cmd="$1"; shift || true
case "$cmd" in
  available) printf 'system    debian-12-standard_12.7-1_amd64.tar.zst\n' ;;
  list)      printf 'local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst  120.00MB\n' ;;
  download)  exit 0 ;;
  *)         exit 0 ;;
esac
STUBEOF

chmod +x "$STUB/pct" "$STUB/pvesm" "$STUB/pveam"
export PATH="$STUB:$PATH"
export PDB_TEST_STATE="$STATE"
export PVE_ETC="$WORK/pve-etc"
mkdir -p "$PVE_ETC/lxc"

run() { bash "$ROOT/install/proton-download-box.sh" "$@" 2>"$WORK/stderr"; }

printf '%s==>%s Argumente und Validierung\n' "$B" "$N"

if run --help 2>&1 | grep -q 'proton-download-box'; then
  pass "--help zeigt Projektname"
else
  fail "--help"
fi

if run --nonsense >/dev/null 2>&1; then
  fail "unbekannte Option wird abgelehnt"
else
  pass "unbekannte Option wird abgelehnt"
fi

if run --port 70000 >/dev/null 2>&1; then
  fail "Port 70000 wird abgelehnt"
else
  pass "Port 70000 wird abgelehnt"
fi

if run --id 99 >/dev/null 2>&1; then
  fail "ID 99 wird abgelehnt"
else
  pass "ID 99 wird abgelehnt"
fi

if run --id 1000 >/dev/null 2>&1; then
  fail "ID 1000 wird abgelehnt"
else
  pass "ID 1000 wird abgelehnt"
fi

if run --ram 512 >/dev/null 2>&1; then
  fail "RAM 512 wird abgelehnt"
else
  pass "RAM 512 wird abgelehnt"
fi

if run --hostname 'bad_name!' >/dev/null 2>&1; then
  fail "ungültiger Hostname wird abgelehnt"
else
  pass "ungültiger Hostname wird abgelehnt"
fi

if run --web-password "bad'quote" >/dev/null 2>&1; then
  fail "Passwort mit Hochkomma wird abgelehnt"
else
  pass "Passwort mit Hochkomma wird abgelehnt"
fi

printf '%s==>%s Dry-Run (Neuinstallation)\n' "$B" "$N"

out=$(run --dry-run --local-dir "$ROOT" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "dry-run beendet mit 0"
else
  fail "dry-run beendet mit $rc"
  cat "$WORK/stderr"
fi

if grep -q 'Neuinstallation' <<<"$out"; then
  pass "dry-run: Neuinstallation erkannt"
else
  fail "dry-run: Neuinstallation"
fi

if grep -q 'Nächste freie CT-ID: 100' <<<"$out"; then
  pass "nächste freie CT-ID: 100"
else
  fail "nächste freie CT-ID"
fi

if grep -q 'rootfs=local' <<<"$out"; then
  pass "dry-run: Storage automatisch gewählt"
else
  fail "dry-run: Storage"
fi

printf '%s==>%s Nächste freie ID mit belegten IDs\n' "$B" "$N"
printf '1' >"$STATE/ct-100"; printf '1' >"$STATE/ct-101"
out=$(run --dry-run --local-dir "$ROOT" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'Nächste freie CT-ID: 102' <<<"$out"; then
  pass "IDs 100/101 belegt → 102"
else
  fail "nächste freie ID mit belegten IDs"
fi

printf '%s==>%s Update-Erkennung\n' "$B" "$N"
out=$(run --dry-run --local-dir "$ROOT" --id 100 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'Update-Modus' <<<"$out"; then
  pass "bestehender CT wird als Update erkannt"
else
  fail "Update-Erkennung"
fi

printf '%s==>%s Fremde CT\n' "$B" "$N"
touch "$STATE/foreign-110"
if run --dry-run --local-dir "$ROOT" --id 110 >/dev/null 2>&1; then
  fail "fremder CT wird abgelehnt"
else
  pass "fremder CT wird abgelehnt"
fi

printf '%s==>%s Statische IP\n' "$B" "$N"
out=$(run --dry-run --local-dir "$ROOT" --ip 192.168.1.50/24 --gw 192.168.1.1 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -q '192.168.1.50/24' <<<"$out"; then
  pass "statische IP wird übernommen"
else
  fail "statische IP"
fi

printf '%s==>%s Payload\n' "$B" "$N"
tar -czf "$WORK/payload.tar.gz" -C "$ROOT" \
  --exclude='app/frontend/node_modules' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  scripts app config
tar -tzf "$WORK/payload.tar.gz" >"$WORK/payload.list"

for f in scripts/install-inside.sh app/backend/main.py app/frontend/dist/index.html config/proton-download-box.service; do
  if grep -qx "$f" "$WORK/payload.list"; then
    pass "Tarball enthält $f"
  else
    fail "Tarball fehlt: $f"
  fi
done

if grep -q 'node_modules' "$WORK/payload.list"; then
  fail "Tarball enthält node_modules"
else
  pass "Tarball enthält kein node_modules"
fi

printf '\n'
if [[ $FAILS -eq 0 ]]; then
  printf '%sINSTALLER TEST PASSED%s\n' "$G" "$N"
  exit 0
fi
printf '%sINSTALLER TEST FAILED (%d)%s\n' "$R" "$FAILS" "$N"
exit 1
