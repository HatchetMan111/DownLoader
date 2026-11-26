#!/usr/bin/env bash
# =============================================================================
#  pve-reboot-test.sh – Nachweistest auf dem Proxmox-Host
#
#  Belegt den geforderten Testdurchlauf:
#    Installation → Reboot des LXC → Web UI wieder erreichbar (mit Logs)
#
#  Nutzung (root auf dem Proxmox-Host):
#     bash test/pve-reboot-test.sh --id 121 [--port 8080]
# =============================================================================
set -Eeuo pipefail

CT_ID=""
APP_NAME="proton-download-box"
PORT=8080

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) CT_ID="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    -h|--help) echo "Nutzung: bash test/pve-reboot-test.sh --id <CT-ID> [--port 8080]"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen"; exit 1; }
command -v pct >/dev/null 2>&1 || { echo "pct fehlt – bitte auf dem Proxmox-Host ausführen"; exit 1; }
[[ -n "$CT_ID" ]] || { echo "Bitte --id <CT-ID> angeben"; exit 1; }
pct config "$CT_ID" >/dev/null 2>&1 || { echo "CT $CT_ID existiert nicht"; exit 1; }

echo "==> [1/4] Service + Web UI vor dem Reboot"
pct exec "$CT_ID" -- systemctl is-active --quiet "${APP_NAME}" \
  || { echo "  xx  Service nicht aktiv – Installation unvollständig"; exit 1; }
pct exec "$CT_ID" -- systemctl is-enabled --quiet "${APP_NAME}" \
  && echo "  ok  Service enabled (Autostart)" || echo "  !!  Service nicht enabled"
ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
echo "  ok  Service aktiv, IP ${ip}"
curl -fsS --max-time 10 "http://${ip}:${PORT}/api/health"
echo

echo "==> [2/4] Container rebooten"
pct reboot "$CT_ID"
for _ in $(seq 1 90); do
  pct exec "$CT_ID" -- true >/dev/null 2>&1 && break
  sleep 1
done

echo "==> [3/4] Service + Web UI nach dem Reboot"
pct exec "$CT_ID" -- systemctl is-active --quiet "${APP_NAME}" \
  || { echo "  xx  Service nach Reboot nicht aktiv"; exit 1; }
echo "  ok  Service nach Reboot aktiv (systemd Autostart)"
for _ in $(seq 1 60); do
  curl -fsS --max-time 5 "http://${ip}:${PORT}/api/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --max-time 10 "http://${ip}:${PORT}/api/health"
echo

echo "==> [4/4] Log-Auszug"
pct exec "$CT_ID" -- systemctl status "${APP_NAME}" --no-pager -l | head -n 12
echo
pct exec "$CT_ID" -- journalctl -u "${APP_NAME}" --no-pager -n 15 | tail -n 15

echo
echo "ERGEBNIS: Installation → Reboot → Web UI erreichbar: OK"
