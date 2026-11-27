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
# Vollständiges Logging: die CLI verschluckt Fehler an der Oberfläche,
# die Ursache steht nur im Debug-Log.
export PROTON_VPN_DEBUG=true
unset XDG_RUNTIME_DIR
# Bevorzugt die persistente Keyring-Session des pdb-keyring-Dienstes –
# nur so sieht Proton denselben SecretService wie beim Verbindungsaufbau.
if [[ -r /run/pdb-keyring/env.sh ]]; then
  # shellcheck disable=SC1091
  . /run/pdb-keyring/env.sh
else
  eval "$(dbus-launch --sh-syntax 2>/dev/null)" >/dev/null 2>&1 || true
  # Keyring mit dem RDP-Passwort entsperren (Datei legt der Installer an).
  KEYRING_PW=""
  [[ -r "$HOME/.pdb-keyring-pass" ]] && KEYRING_PW=$(head -n1 "$HOME/.pdb-keyring-pass" 2>/dev/null)
  printf '%s\n' "$KEYRING_PW" | gnome-keyring-daemon --unlock --replace \
    --components=secrets >/dev/null 2>&1 || true
fi

# --- LAN-Route: RDP/Samba/Web-UI bleiben trotz Tunnel erreichbar -------------
lan_fix() {
  # Bevorzugt der root-Helfer (per sudoers freigegeben) – als normaler
  # Benutzer lassen sich keine Routen/Regeln setzen.
  if [[ -x /usr/local/bin/pdb-lan-fix ]] && sudo -n /usr/local/bin/pdb-lan-fix 2>/dev/null; then
    return 0
  fi
  local ip4 lan gw
  ip4=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4; exit}')
  [[ -n "$ip4" ]] || return 1
  lan=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' \
        "$ip4" 2>/dev/null) || return 1
  gw=$(ip route show default dev eth0 2>/dev/null | awk '{print $3; exit}')
  [[ -n "$gw" ]] || return 1
  ip route replace "$lan" via "$gw" dev eth0 2>/dev/null || return 1
  ip rule del to "$lan" lookup main priority 100 2>/dev/null || true
  ip rule add to "$lan" lookup main priority 100 2>/dev/null || return 1
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
  printf '\nAnmeldung nicht möglich – falls bereits angemeldet, Session erneuern …\n'
  protonvpn signout >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  if ! protonvpn signin "$PUSER" $TOTP; then
    printf '\nAnmeldung fehlgeschlagen. Prüfe Email/Passwort und versuche es erneut.\n'
    exit 1
  fi
fi

printf '\n=== Verbinden (schnellster Free-Server)\n'

# Debian 12 hat NetworkManager 1.42 – ohne natives WireGuard. Proton wählt
# per Default WireGuard, findet dann aber kein Backend ("Backend: None")
# und läuft in einen Timeout. Deshalb Protokoll explizit setzen und
# durchprobieren: OpenVPN (TCP → UDP) und zuletzt WireGuard.
set_protocol() {
  local proto=$1
  mkdir -p "$HOME/.config/Proton/VPN"
  python3 - "$HOME/.config/Proton/VPN/settings.json" "$proto" <<'PY' 2>/dev/null || true
import json, os, sys
path, proto = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data["protocol"] = proto
json.dump(data, open(path, "w"), indent=4)
PY
}

CONNECTED=false

# Killswitch VOR dem ersten Versuch ausschalten: Proton baut ihn als
# Dummy-Interface auf und bricht den gesamten Verbindungsaufbau ab, wenn
# dieser Schritt scheitert (im Container der Fall). Erst nach einer
# erfolgreichen Verbindung wird er wieder aktiviert.
printf '\n  Killswitch für den Aufbau deaktivieren …\n'
protonvpn config set kill-switch off 2>&1 | sed 's/^/    /' || true

for proto in openvpn-tcp openvpn-udp wireguard; do
  printf '\n  Protokoll: %s\n' "$proto"
  set_protocol "$proto"
  if protonvpn connect; then
    CONNECTED=true
    printf '  verbunden mit %s\n' "$proto"
    break
  fi
  # Killswitch vor dem ersten erfolgreichen Verbinden ausschalten
  protonvpn config set kill-switch off >/dev/null 2>&1 || true
  sleep 1
done

# NetworkManager hat keine aktive Verbindung? Dann eth0 übernehmen und erneut.
if [[ "$CONNECTED" != true ]] && [[ -x /usr/local/bin/pdb-nm-takeover ]]; then
  printf '\nNM verwaltet eth0 nicht – versuche Übernahme (mit Rollback) …\n'
  if sudo -n /usr/local/bin/pdb-nm-takeover 2>/dev/null \
     || /usr/local/bin/pdb-nm-takeover; then
    sleep 2
    set_protocol openvpn-tcp
    printf 'Neuer Verbindungsversuch …\n'
    protonvpn connect && CONNECTED=true
  fi
fi

# Autorisierung freischalten (Polkit/NM) und erneut versuchen.
if [[ "$CONNECTED" != true ]] && [[ -x /usr/local/bin/pdb-fix-nm-auth ]]; then
  printf '\nAutorisierung prüfen/freischalten …\n'
  if sudo -n /usr/local/bin/pdb-fix-nm-auth 2>/dev/null \
     || /usr/local/bin/pdb-fix-nm-auth; then
    sleep 3
    set_protocol openvpn-tcp
    printf 'Neuer Verbindungsversuch nach Freischaltung …\n'
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

  printf '\nOpenVPN-Plugin:\n'
  found_plugin=false
  for f in /usr/lib/NetworkManager/*vpn* /usr/lib/*/NetworkManager/*vpn*; do
    [[ -e "$f" ]] || continue
    printf '  %s\n' "${f##*/}"
    found_plugin=true
  done
  [[ "$found_plugin" == true ]] || printf '  FEHLT\n'

  printf '\nNM-Verbindungen (mit Status):\n'
  nmcli -f NAME,TYPE,STATE connection show 2>&1 | head -n 12 | sed 's/^/  /'

  printf '\nProton-Log: letzte Fehler\n'
  grep -E "ERROR|Traceback|Exception" "$HOME"/.cache/Proton/VPN/logs/vpn-cli.log 2>/dev/null \
    | tail -n 12 | sed 's/^/  /'
  printf '\nProton-Log: letzte 15 Zeilen\n'
  tail -n 15 "$HOME"/.cache/Proton/VPN/logs/vpn-cli.log 2>/dev/null | sed 's/^/  /'

  printf '\nPolkit-Regeln:\n'
  if grep -qs 'org.freedesktop.NetworkManager' /etc/polkit-1/rules.d/*.rules; then
    printf '  NetworkManager-Regel vorhanden\n'
  else
    printf '  KEINE NetworkManager-Regel gefunden – NM-Aktionen werden blockiert\n'
  fi
  printf '  polkitd: %s\n' "$(systemctl is-active polkit 2>&1 | head -n1)"

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
sudo -n /usr/local/bin/pdb-lan-fix 2>/dev/null || lan_fix

printf '\n=== Status\n'
protonvpn status || true

printf '\nFertig. Die Box verbindet beim Boot automatisch (pdb-proton-autoconnect).\n'
printf 'Downloads laufen ab jetzt durch den Tunnel; Web-UI und Samba bleiben nutzbar.\n\n'