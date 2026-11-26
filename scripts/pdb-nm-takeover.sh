#!/usr/bin/env bash
# =============================================================================
#  pdb-nm-takeover – eth0 von NetworkManager verwalten lassen
#
#  Proton VPN baut seine Verbindung über NetworkManager auf. Ist eth0 dort
#  "unmanaged", hat NM keine aktive Verbindung und der Tunnelaufbau scheitert
#  ("An unexpected error occurred"). Dieses Skript übernimmt die bestehende
#  IP/Gateway-Konfiguration 1:1 in eine NM-Verbindung – mit Rollback, falls
#  danach kein Netz mehr besteht.
#
#  Aufruf:  pct exec <CT-ID> -- bash /usr/local/bin/pdb-nm-takeover
# =============================================================================
set -u

CONF=/etc/NetworkManager/conf.d/99-proton-download-box.conf
BACKUP=/root/pdb-nm-conf.bak
CON_NAME=pdb-eth0

if [[ $EUID -ne 0 ]]; then
  printf 'Bitte als root ausführen (pct exec).\n'
  exit 1
fi

ip4=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4; exit}')
gw=$(ip route show default dev eth0 2>/dev/null | awk '{print $3; exit}')
if [[ -z "$ip4" || -z "$gw" ]]; then
  printf 'eth0-Konfiguration nicht erkannt (IP=%s GW=%s) – Abbruch.\n' "${ip4:-?}" "${gw:-?}"
  exit 1
fi
printf 'Übernehme: %s via %s\n' "$ip4" "$gw"

# --- Sicherung ---------------------------------------------------------------
[[ -f "$CONF" ]] && cp -f "$CONF" "$BACKUP"
rollback() {
  printf '\n!! Verbindung nach der Übernahme nicht stabil – ROLLBACK\n'
  nmcli connection delete "$CON_NAME" >/dev/null 2>&1 || true
  if [[ -f "$BACKUP" ]]; then
    cp -f "$BACKUP" "$CONF"
  else
    printf '[main]\nplugins=keyfile\ndns=none\n\n[keyfile]\nunmanaged-devices=interface-name:eth0\n' >"$CONF"
  fi
  systemctl restart NetworkManager >/dev/null 2>&1 || true
  sleep 3
  printf 'Rollback abgeschlossen – Container nutzt wieder ifupdown.\n'
  exit 1
}

# --- eth0 für NM freigeben ---------------------------------------------------
if [[ -f "$CONF" ]]; then
  sed -i '/unmanaged-devices/d' "$CONF"
  grep -q '^\[keyfile\]' "$CONF" || printf '\n[keyfile]\n' >>"$CONF"
fi
systemctl reload NetworkManager >/dev/null 2>&1 \
  || systemctl restart NetworkManager >/dev/null 2>&1 || true
sleep 2

# --- identische Verbindung anlegen (idempotent) ------------------------------
nmcli connection delete "$CON_NAME" >/dev/null 2>&1 || true
if ! nmcli connection add type ethernet ifname eth0 con-name "$CON_NAME" \
      ipv4.method manual \
      ipv4.addresses "$ip4" \
      ipv4.gateway "$gw" \
      ipv4.dns "" \
      ipv4.ignore-auto-dns yes \
      ipv6.method disabled \
      connection.autoconnect yes >/dev/null 2>&1; then
  rollback
fi

nmcli connection up "$CON_NAME" >/dev/null 2>&1 || rollback
sleep 2

# --- Erreichbarkeit prüfen ---------------------------------------------------
if ! ping -c1 -W2 "$gw" >/dev/null 2>&1; then
  rollback
fi
if ! ip -4 addr show dev eth0 | grep -q "$ip4"; then
  rollback
fi

printf 'eth0 wird jetzt von NetworkManager verwaltet (%s).\n' "$CON_NAME"
nmcli -t -f NAME,TYPE,DEVICE connection show | sed 's/^/  /'