#!/usr/bin/env bash
# =============================================================================
#  pdb-killswitch – Proton-Killswitch ein/ausschalten (out-of-band)
#
#  Der Killswitch blockiert bei aktivem Tunnel den gesamten LAN-Verkehr – damit
#  sterben RDP/Remmina/Web/Samba. Dieses Skript schaltet ihn ohne Netzwerk-
#  zugang um (via pct exec auf dem Proxmox-Host), also auch dann, wenn die Box
#  per RDP nicht mehr erreichbar ist.
#
#  Aufruf (root auf dem Host):
#     pct exec <CT-ID> -- bash /usr/local/bin/pdb-killswitch off
#     pct exec <CT-ID> -- bash /usr/local/bin/pdb-killswitch on
#     pct exec <CT-ID> -- bash /usr/local/bin/pdb-killswitch status
# =============================================================================
set -u

RDP_USER="${PDB_RDP_USER:-proton}"

# Als root gestartet? Dann als Desktop-Benutzer neu ausführen (Proton läuft
# als dieser User mit seinem Keyring).
if [[ $EUID -eq 0 ]]; then
  exec runuser -u "$RDP_USER" -- bash "$0" "$@"
fi

export HOME="${HOME:-/home/$RDP_USER}"
# Beschreibbares XDG_RUNTIME_DIR (im Container ohne logind vorhanden?).
UID_NUM="$(id -u)"
if [[ -d "/run/user/$UID_NUM" && -w "/run/user/$UID_NUM" ]]; then
  export XDG_RUNTIME_DIR="/run/user/$UID_NUM"
else
  export XDG_RUNTIME_DIR="$HOME/.cache/pdb-runtime"
  mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
  chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
# Keyring-Kontext der persistenten Session, falls vorhanden.
if [[ -r /run/pdb-keyring/env.sh ]]; then
  # shellcheck disable=SC1091
  . /run/pdb-keyring/env.sh
fi
export XDG_RUNTIME_DIR

cmd="${1:-status}"
case "$cmd" in
  on)   protonvpn config set kill-switch standard ;;
  off)  protonvpn config set kill-switch off ;;
  status|*)
    if ! protonvpn config list 2>/dev/null | grep -i 'kill'; then
      protonvpn status 2>/dev/null || echo "Proton-Status nicht verfügbar."
    fi
    ;;
esac