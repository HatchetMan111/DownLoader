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

# Konkrete Route in der Haupttabelle (Vorrang vor dem Tunnel-Default).
# NICHT fatal: schlägt sie fehl (z. B. weil die Kernel-Link-Route das LAN schon
# korrekt führt), ist das LAN trotzdem über die Haupttabelle erreichbar – die
# Policy-Rule unten ist der eigentliche Hebel. Früher killte exit 1 hier die
# gesamte Funktion, BEVOR die Rule gesetzt wurde → LAN blieb tot.
ip route replace "$lan" via "$gw" dev eth0 2>/dev/null \
  || echo "Hinweis: Route $lan nicht explizit gesetzt (Kernel-Link-Route genügt)."

# Policy-Regel: LAN-Ziele immer über die Haupttabelle (Haupthebel gegen den
# Tunnel-Default). Priorität 100 – niedriger als die Tunnel-Regeln, greift zuerst.
ip rule del to "$lan" lookup main priority 100 2>/dev/null || true
ip rule add to "$lan" lookup main priority 100 2>/dev/null || \
  echo "Hinweis: ip rule $lan konnte nicht gesetzt werden."

# Der Proton-Killswitch legt zusätzlich Firewall-Regeln an, die ALLES außer dem
# Tunnel verwirft – damit bricht RDP/Samba trotz korrekter Route ab. Deshalb
# LAN-Verkehr in der Firewall (nft + iptables) VOR dem Drop erlauben. Idempotent.
# nft: eigene Basis-Tabelle, Kette mit frühem Accept fürs LAN.
if command -v nft >/dev/null 2>&1; then
  nft add table inet pdb_lan 2>/dev/null || true
  nft 'add chain inet pdb_lan input { type filter hook input priority -300; policy accept; }' 2>/dev/null || true
  nft add rule inet pdb_lan input ip saddr "$lan" accept 2>/dev/null || true
  nft add rule inet pdb_lan input ip daddr "$lan" accept 2>/dev/null || true
fi
# iptables (falls der Killswitch über iptables-nft arbeitet): LAN vor anderen
# Regeln erlauben. -C prüft Existenz, -I fügt oben ein.
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -s "$lan" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -s "$lan" -j ACCEPT 2>/dev/null || true
  iptables -C INPUT -d "$lan" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -d "$lan" -j ACCEPT 2>/dev/null || true
  iptables -C OUTPUT -d "$lan" -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -d "$lan" -j ACCEPT 2>/dev/null || true
fi

printf 'LAN %s -> %s über eth0 freigeschaltet (Route + Firewall)\n' "$lan" "$gw"