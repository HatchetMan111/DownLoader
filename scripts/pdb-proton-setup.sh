#!/usr/bin/env bash
# =============================================================================
#  pdb-proton-setup – Proton VPN komplett headless einrichten
#
#  Aufruf auf dem Proxmox-Host:
#     pct exec <CT-ID> -- bash /usr/local/bin/pdb-proton-setup
#
#  Oder ohne Installation direkt aus dem Netz:
#     pct exec <CT-ID> -- bash -c 'curl -fsSL -o /tmp/pdb-setup.sh \
#       https://raw.githubusercontent.com/HatchetMan111/DownLoader/main/scripts/pdb-proton-setup.sh \
#       && bash /tmp/pdb-setup.sh'
#
#  Fragt einmalig Proton-Email + Passwort ab, aktiviert den Killswitch,
#  verbindet und sorgt dafür, dass RDP/Samba/Web-UI erreichbar bleiben.
# =============================================================================
set -u

RDP_USER="${PDB_RDP_USER:-proton}"

# Als root gestartet? Dann als Desktop-Benutzer neu ausführen.
if [[ $EUID -eq 0 ]]; then
  exec runuser -u "$RDP_USER" -- bash "$0" "$@"
fi

# --- Session-Umgebung (pct exec vererbt ein kaputtes XDG_RUNTIME_DIR) --------
export HOME="${HOME:-/home/$RDP_USER}"
unset XDG_RUNTIME_DIR
eval "$(dbus-launch --sh-syntax 2>/dev/null)" >/dev/null 2>&1 || true
printf '\n' | gnome-keyring-daemon --unlock --replace --components=secrets \
  >/dev/null 2>&1 || true

# --- LAN-Route: RDP/Samba/Web-UI bleiben trotz Tunnel erreichbar -------------
lan_fix() {
  local ip4 lan gw
  ip4=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4; exit}')
  [[ -n "$ip4" ]] || return 0
  lan=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' \
        "$ip4" 2>/dev/null) || return 0
  gw=$(ip route show default dev eth0 2>/dev/null | awk '{print $3; exit}')
  [[ -n "$gw" ]] || return 0
  ip route replace "$lan" via "$gw" dev eth0 2>/dev/null || true
  ip rule del to "$lan" lookup main priority 100 2>/dev/null || true
  ip rule add to "$lan" lookup main priority 100 2>/dev/null || true
  printf 'LAN %s über %s freigeschaltet (RDP/Samba bleiben erreichbar)\n' "$lan" "$gw"
}

if [[ $EUID -ne 0 ]] && ! command -v ip >/dev/null 2>&1; then
  : # ip fehlt – LAN-Fix wird übersprungen
fi

if ! command -v protonvpn >/dev/null 2>&1; then
  printf '\n  protonvpn-CLI ist nicht installiert. Im Container nachziehen:\n'
  printf '     apt-get update && apt-get install -y proton-vpn-cli\n'
  printf '  (Repo wird vom Installer eingerichtet; danach dieses Skript erneut starten.)\n\n'
  exit 1
fi

printf '\n=== Proton VPN einrichten (kostenloser Account)\n'

SIGNED_IN=false
if protonvpn info >/dev/null 2>&1; then
  SIGNED_IN=true
  printf 'Bereits angemeldet – Anmeldung wird übersprungen.\n'
fi

if [[ "$SIGNED_IN" != true ]]; then
  printf 'Account anlegen (falls nötig): https://account.proton.me/vpn\n\n'

  read -rp 'Proton-Email: ' PUSER || PUSER=""
  if [[ -z "${PUSER:-}" ]]; then
    printf 'Keine Email eingegeben – Abbruch.\n'
    exit 1
  fi

  TOTP=""
  read -rp 'Authenticator-App / 2FA-Code statt Security-Key? [j/N] ' ans || ans=""
  case "${ans,,}" in
    j*) TOTP="--totp" ;;
  esac

  printf '\nPasswort (Eingabe bleibt unsichtbar):\n'
  # shellcheck disable=SC2086  # $TOTP soll bei leerer Variable verschwinden
  if ! protonvpn signin "$PUSER" $TOTP; then
    printf '\nAnmeldung fehlgeschlagen. Prüfe Email/Passwort und versuche es erneut.\n'
    exit 1
  fi
fi

printf '\n=== Verbinden (schnellster Free-Server)\n'
CONNECTED=false
if protonvpn connect; then
  CONNECTED=true
else
  printf '\nErster Versuch fehlgeschlagen – Killswitch temporär aus, neuer Versuch …\n'
  protonvpn config set kill-switch off >/dev/null 2>&1 || true
  sleep 2
  protonvpn connect && CONNECTED=true
fi

# NetworkManager hat keine aktive Verbindung? Dann eth0 übernehmen und erneut.
if [[ "$CONNECTED" != true ]] && [[ -x /usr/local/bin/pdb-nm-takeover ]]; then
  printf '\nNM verwaltet eth0 nicht – versuche Übernahme (mit Rollback) …\n'
  if /usr/local/bin/pdb-nm-takeover; then
    sleep 2
    printf 'Neuer Verbindungsversuch …\n'
    protonvpn connect && CONNECTED=true
  fi
fi

if [[ "$CONNECTED" != true ]]; then
  printf '\n--- Verbindung fehlgeschlagen: Diagnose ---\n'
  printf 'TUN-Gerät: '
  if [[ -c /dev/net/tun ]]; then
    printf 'vorhanden (/dev/net/tun)\n'
  else
    printf 'FEHLT (/dev/net/tun) – im LXC durchreichen\n'
  fi
  printf 'NetworkManager: %s\n' "$(systemctl is-active NetworkManager 2>&1 | head -n1)"
  printf 'Von NM verwaltete Verbindungen:\n'
  nmcli -t -f NAME,TYPE,DEVICE connection show 2>&1 | head -n 8 | sed 's/^/  /'
  printf 'Netzwerk-Interfaces:\n'
  ip -brief addr 2>&1 | sed 's/^/  /'
  printf '\nVerbose-Ausgabe:\n'
  protonvpn --verbose connect 2>&1 | tail -n 25 | sed 's/^/  /'

  printf '\nProton-Logs:\n'
  shopt -s nullglob
  for f in "$HOME"/.cache/*[Pp]roton*[Vv][Pp][Nn]/logs/* \
           "$HOME"/.cache/ProtonVPN/logs/* \
           "$HOME"/.cache/protonvpn/logs/*; do
    [[ -f "$f" ]] || continue
    printf '  --- %s\n' "$f"
    tail -n 12 "$f" 2>/dev/null | sed 's/^/  /'
  done
  shopt -u nullglob
fi

printf '\n=== Killswitch aktivieren\n'
if [[ "$CONNECTED" == true ]]; then
  protonvpn config set kill-switch standard \
    || printf 'Hinweis: Killswitch konnte nicht gesetzt werden.\n'
else
  printf 'übersprungen (keine Verbindung) – nach erfolgreichem Verbinden nachholen:\n'
  printf "  protonvpn config set kill-switch standard\n"
fi

printf '\n=== LAN freischalten\n'
lan_fix

printf '\n=== Status\n'
protonvpn status || true

printf '\nFertig. Die Box verbindet beim Boot automatisch (pdb-proton-autoconnect).\n'
printf 'Downloads laufen ab jetzt durch den Tunnel; Web-UI und Samba bleiben nutzbar.\n\n'