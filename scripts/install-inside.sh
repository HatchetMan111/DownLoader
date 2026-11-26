#!/usr/bin/env bash
# =============================================================================
#  proton-download-box – in-container installer
#
#  Runs *inside* the freshly created Debian 12 LXC. Installs:
#    - XFCE + xrdp            (desktop for the official Proton VPN app)
#    - Proton VPN Free app    (kill switch is configured in its UI)
#    - NetworkManager         (manages the tunnel, leaves eth0 alone)
#    - FastAPI + React UI     (systemd service, port 8080)
#    - Samba share            (easy file pickup from Windows/macOS)
#
#  Invoked by install/proton-download-box.sh. Idempotent: re-running updates
#  the app and keeps existing passwords.
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="2026-11-26.4"

PAYLOAD_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# umask normalisieren: pct exec / lxc-attach erbt die umask des Host-Prozesses,
# und der Host-Installer setzt 077 für die Passwort-Datei. Ohne Reset würden
# hier Dateien als 0600 landen (apt's _apt-User könnte den Keyring nicht
# lesen → "Unknown error executing apt-key").
umask 022
PORT="${PDB_PORT:-8080}"
TZ_VALUE="${PDB_TZ:-Europe/Berlin}"
WEB_PASSWORD="${PDB_PASSWORD:-}"
RDP_USER="${PDB_RDP_USER:-proton}"
RDP_PASSWORD="${PDB_RDP_PASSWORD:-}"
SMB_USER="${PDB_SMB_USER:-$RDP_USER}"
SMB_PASSWORD="${PDB_SMB_PASSWORD:-$RDP_PASSWORD}"

LOG_FILE="/var/log/proton-download-box-install.log"
APP_DIR="/opt/proton-download-box"
APP_USER="protonbox"
ENV_FILE="/etc/proton-download-box.env"
CRED_FILE="/root/proton-download-box-credentials.txt"
SMB_CONF="/etc/samba/smb-proton-download-box.conf"

mkdir -p /var/log
{
  printf '\n\n========== install run %s ==========\n' "$(date -Is)"
} >>"$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ -t 1 ]]; then
  C_B=$'\033[1m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

msg()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  xx%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

on_error() {
  local rc=$? i
  set +e
  {
    printf '\n%s\n' "================= INSTALLATION FAILED ================="
    printf 'exit code  : %s\n' "$rc"
    printf 'line       : %s\n' "${BASH_LINENO[0]:-unknown}"
    printf 'command    : %s\n' "${BASH_COMMAND:-unknown}"
    printf 'function   : %s\n' "${FUNCNAME[1]:-main}"
    printf 'call stack :\n'
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      printf '   at %s (%s:%s)\n' \
        "${FUNCNAME[$i]}" "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$i - 1]:-?}"
    done
    printf 'log file   : %s\n' "$LOG_FILE"
    printf '\n--- systemctl status proton-download-box ---\n'
    systemctl status proton-download-box --no-pager -l 2>&1 | tail -n 30
    printf '\n--- journalctl -u proton-download-box (last 80) ---\n'
    journalctl -u proton-download-box --no-pager -n 80 2>&1
    printf '\n--- last 60 log lines ---\n'
    tail -n 60 "$LOG_FILE" 2>/dev/null
    printf '%s\n' "======================================================"
  } >&2
  exit "$rc"
}
trap on_error ERR

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LC_ALL=C LANG=C   # keine Locales im Slim-Template → Warnungen unterdrücken
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '/+=' | cut -c1-20
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
  fi
}

apt_update() {
  msg "apt-Quellen aktualisieren"
  if ! apt-get update -qq; then
    warn "apt-get update fehlgeschlagen – wiederhole mit vollem Output:"
    apt-get update 2>&1 | tail -n 40 || true
    die "apt-get update fehlgeschlagen (Details oben)"
  fi
}

apt_install() {
  local pkgs=() pkg
  for pkg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      pkgs+=("$pkg")
    fi
  done
  if ((${#pkgs[@]} == 0)); then
    ok "Pakete bereits vorhanden: $*"
    return 0
  fi
  msg "apt install: ${pkgs[*]}"
  apt-get install "${APT_OPTS[@]}" --no-install-recommends "${pkgs[@]}"
}

apt_install_full() {
  local pkgs=() pkg
  for pkg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      pkgs+=("$pkg")
    fi
  done
  if ((${#pkgs[@]} == 0)); then
    ok "Pakete bereits vorhanden: $*"
    return 0
  fi
  msg "apt install: ${pkgs[*]}"
  apt-get install "${APT_OPTS[@]}" "${pkgs[@]}"
}

wait_for_http() {
  local url=$1 tries=${2:-30} i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# --------------------------------------------------------------------------- #
# 0. sanity
# --------------------------------------------------------------------------- #

[[ $EUID -eq 0 ]] || die "install-inside.sh muss als root laufen"
[[ -f "$PAYLOAD_DIR/app/backend/main.py" ]] || die "Payload unvollständig: $PAYLOAD_DIR/app/backend/main.py fehlt"
[[ -f "$PAYLOAD_DIR/config/proton-download-box.service" ]] || die "Payload unvollständig: systemd-Unit fehlt"

if [[ -f "$ENV_FILE" ]]; then
  [[ -n "$WEB_PASSWORD" ]] || WEB_PASSWORD=$(sed -n 's/^PDB_PASSWORD=//p' "$ENV_FILE" | head -n1)
fi
if [[ -f "$CRED_FILE" ]]; then
  [[ -n "$RDP_PASSWORD" ]] || RDP_PASSWORD=$(sed -n 's/^RDP_PASSWORD=//p' "$CRED_FILE" | head -n1)
  [[ -n "$SMB_PASSWORD" ]] || SMB_PASSWORD=$(sed -n 's/^SMB_PASSWORD=//p' "$CRED_FILE" | head -n1)
fi
[[ -n "$WEB_PASSWORD" ]] || WEB_PASSWORD=$(gen_password)
[[ -n "$RDP_PASSWORD" ]] || RDP_PASSWORD=$(gen_password)
[[ -n "$SMB_PASSWORD" ]] || SMB_PASSWORD="$RDP_PASSWORD"

msg "proton-download-box wird installiert (Port $PORT) – Installer-Version $SCRIPT_VERSION"

# --------------------------------------------------------------------------- #
# 1. timezone + base packages
# --------------------------------------------------------------------------- #

if [[ -n "$TZ_VALUE" && -f "/usr/share/zoneinfo/$TZ_VALUE" ]]; then
  ln -sf "/usr/share/zoneinfo/$TZ_VALUE" /etc/localtime
  printf '%s\n' "$TZ_VALUE" >/etc/timezone
  ok "Zeitzone: $TZ_VALUE"
fi

apt_update

apt_install \
  curl ca-certificates gnupg lsb-release jq sudo nano less \
  tar gzip xz-utils unzip rsync openssl \
  python3 python3-venv python3-pip \
  dbus dbus-x11 \
  procps iproute2 iputils-ping net-tools \
  cron logrotate

# --------------------------------------------------------------------------- #
# 2. Proton VPN repository
# --------------------------------------------------------------------------- #

msg "Proton-VPN-Repository einrichten"
install -d -m 0755 /usr/share/keyrings /etc/apt/keyrings

KEYRING_URL="https://repo.protonvpn.com/debian/public_key.asc"
KEYRING="/usr/share/keyrings/protonvpn-stable-archive-keyring.gpg"
# Legacy-Keyrings früherer Versionen entfernen
rm -f /etc/apt/keyrings/protonvpn-stable-archive-keyring.asc \
      /usr/share/keyrings/protonvpn-public.asc

if [[ ! -s "$KEYRING" ]]; then
  curl -fsSL --retry 3 --retry-delay 2 "$KEYRING_URL" -o /tmp/proton-public.asc \
    || die "Proton-Schlüssel konnte nicht geladen werden: $KEYRING_URL"
  [[ -s /tmp/proton-public.asc ]] || die "Schlüssel-Datei ist leer: $KEYRING_URL"
  if ! grep -q "BEGIN PGP PUBLIC KEY BLOCK" /tmp/proton-public.asc; then
    head -c 200 /tmp/proton-public.asc >&2 || true
    rm -f /tmp/proton-public.asc
    die "Schlüssel-Datei enthält keinen PGP-Public-Key-Block (Download defekt?)"
  fi
  # Container-sicher dearmoren: reines Python-stdlib – KEIN gpg/agent (der
  # verursacht in unprivilegierten LXC "Unknown error executing apt-key";
  # gpgv läuft dagegen einwandfrei, wie das erfolgreiche Basis-apt-Update zeigt).
  python3 - "$KEYRING" <<'PYEOF' || die "Keyring-Erzeugung (dearmor) fehlgeschlagen"
import base64, re, sys
src = "/tmp/proton-public.asc"
text = open(src, encoding="utf-8", errors="replace").read()
match = re.search(
    r"-----BEGIN PGP PUBLIC KEY BLOCK-----(.*?)-----END PGP PUBLIC KEY BLOCK-----",
    text, re.S,
)
if not match:
    sys.exit("kein PGP-Public-Key-Block gefunden")
lines = [line.strip() for line in match.group(1).splitlines()]
lines = [line for line in lines if line and not line.startswith(":")]
if lines and lines[-1].startswith("="):
    lines = lines[:-1]  # CRC-Prüfsummen-Zeile
open(sys.argv[1], "wb").write(base64.b64decode("".join(lines)))
PYEOF
  rm -f /tmp/proton-public.asc
  [[ -s "$KEYRING" ]] || die "Keyring nach Dearmor leer – Abbruch."
  chmod 0644 "$KEYRING"
fi

# Fail fast mit vollen Diagnosen statt kryptischem apt-GPG-Fehler:
# dieselbe Verifikation, die apt macht (gpgv), direkt ausführen.
curl -fsSL --retry 3 --retry-delay 2 \
  https://repo.protonvpn.com/debian/dists/stable/InRelease -o /tmp/proton-InRelease \
  || die "InRelease konnte nicht geladen werden"
if ! gpgv --keyring "$KEYRING" /tmp/proton-InRelease 2>/tmp/proton-gpgv.err; then
  warn "gpgv-Verifikation fehlgeschlagen – Diagnose:"
  cat /tmp/proton-gpgv.err >&2 || true
  ls -la "$KEYRING" >&2 || true
  file "$KEYRING" >&2 || true
  head -c 120 /tmp/proton-InRelease >&2 || true
  rm -f /tmp/proton-InRelease
  die "Proton-Keyring im Container nicht verwendbar – Details oben"
fi
rm -f /tmp/proton-InRelease /tmp/proton-gpgv.err
ok "Keyring verifiziert (gpgv): $KEYRING"

# --------------------------------------------------------------------------- #
# 3. desktop + Proton VPN app
# --------------------------------------------------------------------------- #

msg "XFCE, xrdp und Hilfsdienste installieren"
apt_install \
  xfce4 xfce4-terminal thunar mousepad \
  x11-xserver-utils xauth xorgxrdp xrdp \
  fonts-dejavu-core adwaita-icon-theme hicolor-icon-theme \
  network-manager network-manager-openvpn network-manager-openvpn-gnome \
  wireguard-tools openvpn \
  polkitd \
  gnome-keyring libpam-gnome-keyring libsecret-tools

# xfce-polkit is optional (a polkit rule below covers NetworkManager anyway)
apt_install xfce-polkit || warn "xfce-polkit nicht verfügbar – weiter ohne"

msg "Proton VPN (kostenlose App) installieren"
apt_install_full \
  proton-vpn-gnome-desktop \
  python3-proton-keyring-linux-secretservice \
  proton-vpn-cli

if command -v protonvpn-app >/dev/null 2>&1 || [[ -x /usr/bin/protonvpn-app ]]; then
  ok "Proton VPN App installiert"
else
  warn "protonvpn-app nicht im PATH gefunden – Paketinstallation prüfen"
fi

# --------------------------------------------------------------------------- #
# 4. users
# --------------------------------------------------------------------------- #

msg "Benutzer einrichten"
if ! getent group "$APP_USER" >/dev/null 2>&1; then
  groupadd --system "$APP_USER"
fi
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin --gid "$APP_USER" "$APP_USER"
  ok "Systembenutzer $APP_USER angelegt"
else
  ok "Systembenutzer $APP_USER existiert"
fi

if ! id -u "$RDP_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,"$APP_USER" "$RDP_USER"
  ok "Desktopbenutzer $RDP_USER angelegt"
else
  usermod -aG sudo,"$APP_USER" "$RDP_USER"
  ok "Desktopbenutzer $RDP_USER aktualisiert"
fi
printf '%s:%s\n' "$RDP_USER" "$RDP_PASSWORD" | chpasswd
ok "Passwort für $RDP_USER gesetzt"

# No screen blanking / lock over RDP – the app must stay visible.
install -d -o "$RDP_USER" -g "$RDP_USER" -m 0755 \
  "/home/$RDP_USER/.config/xfce4/xfconf/xfce-perchannel-xml"
cat >"/home/$RDP_USER/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
  </property>
</channel>
EOF
chown -R "$RDP_USER:$RDP_USER" "/home/$RDP_USER/.config"

# --------------------------------------------------------------------------- #
# 5. xrdp
# --------------------------------------------------------------------------- #

msg "xrdp konfigurieren"
adduser xrdp ssl-cert >/dev/null 2>&1 || true
cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
# Start an XFCE session for xrdp users.
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
if [ -r /etc/profile ]; then
  . /etc/profile
fi
exec startxfce4
EOF
chmod 0755 /etc/xrdp/startwm.sh

# Auto-unlock the GNOME keyring with the login password (Proton stores the
# session there). "optional" means a missing module never blocks login.
if [[ -f /etc/pam.d/xrdp-sesman ]] && ! grep -q 'pam_gnome_keyring' /etc/pam.d/xrdp-sesman; then
  {
    printf 'auth       optional     pam_gnome_keyring.so\n'
    printf 'session    optional     pam_gnome_keyring.so auto_start\n'
  } >>/etc/pam.d/xrdp-sesman
fi

systemctl enable xrdp >/dev/null 2>&1
systemctl restart xrdp
ok "xrdp aktiv (Port 3389)"

# --------------------------------------------------------------------------- #
# 6. NetworkManager: manage the tunnel, never touch eth0
# --------------------------------------------------------------------------- #

msg "NetworkManager konfigurieren"
install -d -m 0755 /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/99-proton-download-box.conf <<'EOF'
[main]
plugins=keyfile
dns=none

[keyfile]
unmanaged-devices=interface-name:eth0
EOF

# Keep DNS working: while the tunnel is up, use Proton's resolver.
[[ -f /etc/resolv.conf.pdb-orig ]] || cp -f /etc/resolv.conf /etc/resolv.conf.pdb-orig
install -d -m 0755 /etc/NetworkManager/dispatcher.d
cat >/etc/NetworkManager/dispatcher.d/50-proton-download-box <<'EOF'
#!/usr/bin/env bash
# Point the container at Proton's DNS while the tunnel is up, restore after.
set -u
IFACE="${1:-}"
ACTION="${2:-}"
ORIG=/etc/resolv.conf.pdb-orig

case "$ACTION" in
  up|vpn-up)
    case "$IFACE" in
      proton*|wg*|tun*|tap*)
        [ -f "$ORIG" ] || cp -f /etc/resolv.conf "$ORIG" 2>/dev/null || true
        printf 'nameserver 10.2.0.1\nnameserver 10.2.0.2\n' > /etc/resolv.conf
        ;;
    esac
    ;;
  down|vpn-down)
    case "$IFACE" in
      proton*|wg*|tun*|tap*)
        [ -f "$ORIG" ] && cp -f "$ORIG" /etc/resolv.conf
        ;;
    esac
    ;;
esac
exit 0
EOF
chmod 0755 /etc/NetworkManager/dispatcher.d/50-proton-download-box

systemctl enable NetworkManager >/dev/null 2>&1
systemctl restart NetworkManager
ok "NetworkManager läuft, eth0 bleibt unmanaged"

# Let the desktop user drive NetworkManager without a polkit prompt.
cat >/etc/polkit-1/rules.d/50-proton-download-box.rules <<EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$RDP_USER" &&
        action.id.indexOf("org.freedesktop.NetworkManager.") === 0) {
        return polkit.Result.YES;
    }
});
EOF

# --------------------------------------------------------------------------- #
# 7. application
# --------------------------------------------------------------------------- #

msg "Anwendung nach $APP_DIR deployen"
install -d -o "$APP_USER" -g "$APP_USER" -m 0755 "$APP_DIR"
install -d -o "$APP_USER" -g "$APP_USER" -m 2775 /srv/downloads
install -d -o "$APP_USER" -g "$APP_USER" -m 0750 /var/lib/proton-download-box

rm -rf "$APP_DIR/backend.new" "$APP_DIR/web.new"
cp -a "$PAYLOAD_DIR/app/backend" "$APP_DIR/backend.new"

if [[ -d "$PAYLOAD_DIR/app/frontend/dist" && -f "$PAYLOAD_DIR/app/frontend/dist/index.html" ]]; then
  cp -a "$PAYLOAD_DIR/app/frontend/dist" "$APP_DIR/web.new"
else
  die "Frontend-Build fehlt (app/frontend/dist). Bitte 'npm ci && npm run build' im Repo ausführen."
fi

rm -rf "$APP_DIR/backend" "$APP_DIR/web"
mv "$APP_DIR/backend.new" "$APP_DIR/backend"
mv "$APP_DIR/web.new" "$APP_DIR/web"
chown -R root:root "$APP_DIR/backend" "$APP_DIR/web"
chmod -R a+rX "$APP_DIR/backend" "$APP_DIR/web"

if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
  msg "Python-venv anlegen"
  python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip wheel
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/backend/requirements.txt"
ok "Python-Abhängigkeiten installiert"

SECRET=""
if [[ -f "$ENV_FILE" ]]; then
  SECRET=$(sed -n 's/^PDB_SECRET=//p' "$ENV_FILE" | head -n1)
fi
[[ -n "$SECRET" ]] || SECRET=$(openssl rand -hex 32)

umask 077
cat >"$ENV_FILE" <<EOF
PDB_PORT=$PORT
PDB_PASSWORD=$WEB_PASSWORD
PDB_SECRET=$SECRET
PDB_DOWNLOAD_DIR=/srv/downloads
PDB_WEB_DIR=$APP_DIR/web
PDB_RDP_USER=$RDP_USER
PDB_SMB_SHARE=downloads
PDB_LOG_LEVEL=info
EOF
chmod 0600 "$ENV_FILE"
ok "Umgebung geschrieben: $ENV_FILE"

install -m 0644 "$PAYLOAD_DIR/config/proton-download-box.service" \
  /etc/systemd/system/proton-download-box.service
systemctl daemon-reload
systemctl enable proton-download-box >/dev/null 2>&1
systemctl restart proton-download-box
ok "systemd-Service gestartet"

# --------------------------------------------------------------------------- #
# 8. Samba
# --------------------------------------------------------------------------- #

msg "Samba-Freigabe einrichten"
apt_install samba

cat >"$SMB_CONF" <<EOF
[downloads]
   comment = Proton Download Box
   path = /srv/downloads
   browseable = yes
   read only = no
   guest ok = no
   valid users = $SMB_USER
   force user = $APP_USER
   force group = $APP_USER
   create mask = 0664
   directory mask = 0775
EOF

if ! grep -qF "$SMB_CONF" /etc/samba/smb.conf; then
  printf '\ninclude = %s\n' "$SMB_CONF" >>/etc/samba/smb.conf
fi

printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -s -a "$SMB_USER" >/dev/null
smbpasswd -e "$SMB_USER" >/dev/null 2>&1 || true

systemctl enable smbd >/dev/null 2>&1 || true
systemctl restart smbd || warn "smbd konnte nicht gestartet werden"
systemctl enable nmbd >/dev/null 2>&1 || true
systemctl restart nmbd >/dev/null 2>&1 || warn "nmbd nicht aktiv (für SMB über IP nicht nötig)"

# --------------------------------------------------------------------------- #
# 9. firewall: only the ports we need
# --------------------------------------------------------------------------- #

msg "Firewall (nftables) einrichten"
apt_install nftables
cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet pdb {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        udp sport 67 udp dport 68 accept
        tcp dport { 22, $PORT, 3389 } accept
        udp dport { 137, 138 } accept
        tcp dport { 139, 445 } accept
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
systemctl enable nftables >/dev/null 2>&1 || true
if nft -f /etc/nftables.conf; then
  ok "Firewall aktiv (22, $PORT, 3389, 137-139, 445 offen)"
else
  nft flush ruleset 2>/dev/null || true
  warn "nftables-Regeln konnten nicht geladen werden – Firewall bleibt aus"
fi

# --------------------------------------------------------------------------- #
# 10. verification
# --------------------------------------------------------------------------- #

msg "Installation verifizieren"
for unit in proton-download-box xrdp; do
  if systemctl is-active --quiet "$unit"; then
    ok "$unit ist aktiv"
  else
    systemctl status "$unit" --no-pager -l 2>&1 | tail -n 25 >&2 || true
    journalctl -u "$unit" --no-pager -n 50 >&2 || true
    die "$unit ist nicht aktiv"
  fi
done

if ! wait_for_http "http://127.0.0.1:${PORT}/api/health" 40; then
  journalctl -u proton-download-box --no-pager -n 80 >&2 || true
  die "Web UI antwortet nicht auf http://127.0.0.1:${PORT}/api/health"
fi
ok "Web UI antwortet auf 127.0.0.1:${PORT}"

CT_IP=$(hostname -I | awk '{print $1}')
if curl -fsS --max-time 5 "http://${CT_IP}:${PORT}/api/health" >/dev/null 2>&1; then
  ok "Web UI erreichbar über ${CT_IP}:${PORT}"
else
  warn "Web UI über ${CT_IP}:${PORT} nicht erreichbar – Firewall wird entschärft"
  nft flush ruleset 2>/dev/null || true
  systemctl disable nftables >/dev/null 2>&1 || true
  if curl -fsS --max-time 5 "http://${CT_IP}:${PORT}/api/health" >/dev/null 2>&1; then
    ok "Web UI nach Firewall-Reset erreichbar"
  else
    die "Web UI auch ohne Firewall nicht über ${CT_IP}:${PORT} erreichbar"
  fi
fi

# --------------------------------------------------------------------------- #
# 11. credentials + summary
# --------------------------------------------------------------------------- #

umask 077
cat >"$CRED_FILE" <<EOF
# proton-download-box – Zugangsdaten
RDP_USER=$RDP_USER
RDP_PASSWORD=$RDP_PASSWORD
SMB_USER=$SMB_USER
SMB_PASSWORD=$SMB_PASSWORD
WEB_PASSWORD=$WEB_PASSWORD
WEB_URL=http://${CT_IP}:${PORT}
EOF
chmod 0600 "$CRED_FILE"

printf '\n'
printf '%s\n' "-------------------------------------------------------------------"
printf '%s\n' " proton-download-box ist bereit"
printf '%s\n' "-------------------------------------------------------------------"
printf ' Web UI      : http://%s:%s\n' "$CT_IP" "$PORT"
printf ' Web-Passwort: %s\n' "$WEB_PASSWORD"
printf ' RDP         : %s:3389  (Benutzer %s)\n' "$CT_IP" "$RDP_USER"
printf ' RDP-Passwort: %s\n' "$RDP_PASSWORD"
printf ' Samba       : \\\\%s\\downloads  (Benutzer %s)\n' "$CT_IP" "$SMB_USER"
printf ' Samba-Passw.: %s\n' "$SMB_PASSWORD"
printf ' Dateien     : /srv/downloads\n'
printf ' Log         : %s\n' "$LOG_FILE"
printf '%s\n' "-------------------------------------------------------------------"
printf '%s\n' " Nächster Schritt: per RDP anmelden, Proton VPN starten, einloggen,"
printf '%s\n' " verbinden und in den Einstellungen den Killswitch aktivieren."
printf '%s\n' "-------------------------------------------------------------------"
printf '\n'
