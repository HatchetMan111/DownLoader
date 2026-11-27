#!/usr/bin/env bash
# =============================================================================
#  pdb-lan-fix – LAN-Verkehr am VPN-Tunnel vorbei (RDP/Samba/Web-UI)
#
#  Sorgt dafür, dass Ziele im eigenen LAN immer über eth0 geroutet werden,
#  auch wenn der Proton-Tunnel aktiv ist. Ohne das bricht die RDP-Sitzung ab,
#  sobald der Tunnel steht.
#
#  Aufruf (root):  pct exec <CT-ID> -- bash /usr/local/bin/pdb-lan-fix
#  Wird zusätzlich vom NetworkManager-Dispatcher bei jedem Tunnelaufbau
#  aufgerufen. Idempotent.
# =============================================================================
set -u

ip4=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4; exit}')
if [[ -z "$ip4" ]]; then
  echo "eth0 hat keine IPv4-Adresse – nichts zu tun."
  exit 0
fi

lan=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' \
      "$ip4" 2>/dev/null) || { echo "LAN konnte nicht berechnet werden."; exit 1; }

gw=$(ip route show default dev eth0 2>/dev/null | awk '{print $3; exit}')
if [[ -z "$gw" ]]; then
  gw=$(printf '%s' "$ip4" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')
fi

# Konkrete Route in der Haupttabelle (Vorrang vor dem Tunnel-Default)
ip route replace "$lan" via "$gw" dev eth0 2>/dev/null || {
  echo "Route $lan konnte nicht gesetzt werden."; exit 1; }

# Policy-Regel: LAN-Ziele immer über die Haupttabelle
ip rule del to "$lan" lookup main priority 100 2>/dev/null || true
ip rule add to "$lan" lookup main priority 100 2>/dev/null || {
  echo "ip rule konnte nicht gesetzt werden."; exit 1; }

printf 'LAN %s -> %s über eth0 freigeschaltet\n' "$lan" "$gw"