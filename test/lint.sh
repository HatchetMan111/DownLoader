#!/usr/bin/env bash
# =============================================================================
#  lint.sh – statische Prüfungen für alle Quell- und Auslieferungsdateien
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="proton-download-box"

cd "$ROOT"

failures=0
ok()   { printf 'ok   %s\n' "$*"; }
fail() { printf 'xx   %s\n' "$*"; failures=$((failures + 1)); }

required_files=(
  "install/${APP_NAME}.sh"
  "scripts/install-inside.sh"
  "config/${APP_NAME}.service"
  "app/backend/main.py"
  "app/backend/requirements.txt"
  "app/frontend/package.json"
  "app/frontend/vite.config.js"
  "app/frontend/index.html"
  "app/frontend/src/main.jsx"
  "app/frontend/src/App.jsx"
  "app/frontend/src/api.js"
  "app/frontend/src/format.js"
  "app/frontend/src/styles.css"
  "app/frontend/src/components/Login.jsx"
  "app/frontend/src/components/StatusPanel.jsx"
  "app/frontend/src/components/Downloader.jsx"
  "app/frontend/src/components/FileManager.jsx"
  "app/frontend/src/components/Icons.jsx"
  "app/frontend/dist/index.html"
  "README.md"
  "docs/TROUBLESHOOTING.md"
)

for file in "${required_files[@]}"; do
  if [[ -f "$file" ]]; then ok "$file"; else fail "$file fehlt"; fi
done

check() {
  if "$@" >/dev/null 2>&1; then
    ok "$*"
  else
    fail "$*"
  fi
}

check bash -n "install/${APP_NAME}.sh"
check bash -n "scripts/install-inside.sh"
check bash -n "test/smoke.sh"
check bash -n "test/installer.sh"
check bash -n "test/pve-reboot-test.sh"

if command -v shellcheck >/dev/null 2>&1; then
  check shellcheck -x -S style "install/${APP_NAME}.sh"
  check shellcheck -x -S style "scripts/install-inside.sh"
  check shellcheck -x -S warning "test/smoke.sh"
  check shellcheck -x -S warning "test/installer.sh"
  check shellcheck -x -S warning "test/pve-reboot-test.sh"
else
  echo "!! shellcheck nicht installiert – übersprungen"
fi

if command -v python3 >/dev/null 2>&1; then
  check python3 -m py_compile "app/backend/main.py"
fi

if [[ -f "app/frontend/dist/index.html" ]] \
  && grep -q 'assets/index-' "app/frontend/dist/index.html"; then
  ok "dist referenziert gebaute Assets"
else
  fail "app/frontend/dist/index.html fehlt oder ist alt"
fi

if grep -q 'Restart=always' "config/${APP_NAME}.service" \
  && grep -q 'After=network-online.target' "config/${APP_NAME}.service" \
  && grep -q 'WantedBy=multi-user.target' "config/${APP_NAME}.service"; then
  ok "systemd-Unit: Restart=always + After=network-online.target"
else
  fail "systemd-Unit unvollständig"
fi

if grep -q 'set -Eeuo pipefail' "install/${APP_NAME}.sh" \
  && grep -q 'pct create' "install/${APP_NAME}.sh" \
  && grep -q -- '--onboot 1' "install/${APP_NAME}.sh"; then
  ok "Installer: set -Eeuo pipefail, pct create, onboot=1"
else
  fail "Installer: Pflichtbestandteile fehlen"
fi

# Payload: vollständig und klein (kein node_modules) – exakt wie im Installer
tmp=$(mktemp -d)
tar -czf "$tmp/payload.tar.gz" -C "$ROOT" \
  --exclude='app/frontend/node_modules' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  scripts app config
tar -tzf "$tmp/payload.tar.gz" >"$tmp/payload.list"
if grep -q 'node_modules' "$tmp/payload.list"; then
  fail "Payload enthält node_modules"
else
  ok "Payload enthält kein node_modules"
fi
for f in scripts/install-inside.sh app/backend/main.py app/frontend/dist/index.html "config/${APP_NAME}.service"; do
  grep -qx "$f" "$tmp/payload.list" || fail "Payload fehlt: $f"
done
ok "Payload vollständig ($(du -h "$tmp/payload.tar.gz" | cut -f1))"
rm -rf "$tmp"

if [[ $failures -eq 0 ]]; then
  echo "LINT OK"
  exit 0
fi
echo "LINT FAILED: $failures"
exit 1
