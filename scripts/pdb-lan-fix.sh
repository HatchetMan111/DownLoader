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

# Zu routende Netze: das lokale Subnetz + alle privaten RFC1918-Ranges. So
# erreicht JEDES LAN-Gerät (auch ein Client in 192.168.x / 172.16.x, während die
# Box in 10.x liegt) die Box über eth0 – der Tunnel schluckt sonst den Rückweg.
# onlink erzwingt den Gateway auch ohne passende Link-Route (verhindert den
# "Nexthop has invalid gateway"-Fehler bei aktiver Tunnel-Default-Route).
ranges=("$lan" "192.168.0.0/16" "172.16.0.0/12")

for net in "${ranges[@]}"; do
  # Route in der Haupttabelle (nicht fatal – die Policy-Rule ist der Hebel).
  ip route replace "$net" via "$gw" dev eth0 onlink 2>/dev/null \
    || ip route replace "$net" via "$gw" dev eth0 2>/dev/null \
    || echo "Hinweis: Route $net nicht explizit gesetzt."

  # Policy-Regel: Ziele immer über die Haupttabelle (greift vor den Tunnel-Regeln).
  ip rule del to "$net" lookup main priority 100 2>/dev/null || true
  ip rule add to "$net" lookup main priority 100 2>/dev/null \
    || echo "Hinweis: ip rule $net konnte nicht gesetzt werden."

  # Firewall (nft + iptables): LAN-Verkehr VOR dem Drop erlauben. Idempotent.
  if command -v nft >/dev/null 2>&1; then
    nft add table inet pdb_lan 2>/dev/null || true
    nft 'add chain inet pdb_lan input { type filter hook input priority -300; policy accept; }' 2>/dev/null || true
    nft add rule inet pdb_lan input ip saddr "$net" accept 2>/dev/null || true
    nft add rule inet pdb_lan input ip daddr "$net" accept 2>/dev/null || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -s "$net" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -s "$net" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -d "$net" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -d "$net" -j ACCEPT 2>/dev/null || true
    iptables -C OUTPUT -d "$net" -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -d "$net" -j ACCEPT 2>/dev/null || true
  fi
done

printf 'LAN freigeschaltet über eth0 (gw %s): %s\n' "$gw" "${ranges[*]}"