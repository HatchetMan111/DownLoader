#!/usr/bin/env bash
# =============================================================================
#  proton-download-box – Proxmox VE Community-Style Installer
#
#  Creates a Debian 12 LXC with:
#    - XFCE desktop + xrdp            (official Proton VPN Free app + kill switch)
#    - NetworkManager                  (tunnel management, eth0 left alone)
#    - FastAPI + React/Vite dashboard  (port 8080, file manager + downloader)
#    - Samba share                     (/srv/downloads)
#
#  Quick start (root on the Proxmox host):
#     bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DownLoader/main/install/proton-download-box.sh)"
#
#  Flags:
#     ... | bash -s -- --id 121 --ram 4096 --disk 24 --ip 192.168.1.50/24 --gw 192.168.1.1
#
#  Re-running with the same --id updates the existing container (idempotent).
#  Uninstall:  ... | bash -s -- --uninstall --id 121
# =============================================================================
set -Eeuo pipefail

APP_NAME="proton-download-box"
APP_TITLE="Proton Download Box"
APP_DESC="Proton VPN Free download box with desktop, file manager and web UI"
# Muss zur SCRIPT_VERSION in scripts/install-inside.sh passen. Weicht die
# geladene Payload ab, war der GitHub-Cache veraltet (wird laut gemeldet).
EXPECTED_SCRIPT_VERSION="2026-11-26.18"
PVE_ETC="${PVE_ETC:-/etc/pve}"

# --- GitHub source -----------------------------------------------------------
GITHUB_REPO="${PDB_GITHUB_REPO:-HatchetMan111/DownLoader}"
GITHUB_REF="${PDB_GITHUB_REF:-main}"
REPO_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}"
# Cache-Buster: codeload-Tarballs liegen kurz im Fastly-Cache – ohne Buster
# bekommt ein sofortiger Re-Run u. U. eine ältere Version.
REPO_TARBALL="https://codeload.github.com/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_REF}?nocache=$(date +%s)"

# --- container defaults (override with flags or environment) -----------------
CT_ID="${CT_ID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-proton-download-box}"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-4096}"
SWAP_MB="${SWAP_MB:-1024}"
DISK_GB="${DISK_GB:-24}"
STORAGE="${STORAGE:-}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
GATEWAY="${GATEWAY:-}"
PORT="${PORT:-8080}"
TZ_VALUE="${TZ_VALUE:-Europe/Berlin}"
KBD_LAYOUT="${KBD_LAYOUT:-de}"
RDP_USER="${RDP_USER:-proton}"

# --- secrets (generated when empty, preserved on re-runs) --------------------
WEB_PASSWORD="${WEB_PASSWORD:-}"
RDP_PASSWORD="${RDP_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

# --- modes -------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
CHECK_ONLY=0
UNINSTALL=0
DEBUG=0
LOCAL_DIR="${PDB_LOCAL_DIR:-}"

PAYLOAD_TAR=""
PAYLOAD_TMP=""
INSTALL_ENV=""
REUSE=0

if [[ -t 1 ]]; then
  C_B=$'\033[1m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_C=$'\033[1;36m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi

msg()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  xx%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${C_B}${APP_TITLE}${C_0} – ${APP_DESC}

  bash -c "\$(wget -qLO - ${REPO_RAW}/install/${APP_NAME}.sh)"

Optionen:
  --id <100-999>         Container-ID (Standard: nächste freie ab 100)
  --hostname <name>      Hostname (Standard: ${CT_HOSTNAME})
  --cores <n>            vCPUs (Standard: ${CORES})
  --ram <mb>             RAM in MB (Standard: ${RAM_MB})
  --swap <mb>            Swap in MB (Standard: ${SWAP_MB})
  --disk <gb>            Disk in GB (Standard: ${DISK_GB})
  --storage <name>       Rootfs-Storage (Standard: automatisch)
  --template-storage <n> Storage für das LXC-Template (Standard: automatisch)
  --bridge <name>        Netzwerk-Bridge (Standard: ${BRIDGE})
  --ip <dhcp|addr/cidr>  IP-Konfiguration (Standard: ${IP_CONFIG})
  --gw <ip>              Gateway (nur bei statischer IP)
  --port <port>          Web-UI-Port (Standard: ${PORT})
  --tz <zone>            Zeitzone (Standard: ${TZ_VALUE})
  --kbd <layout>         Tastatur-Layout im RDP-Desktop (Standard: ${KBD_LAYOUT})
  --rdp-user <name>      Desktop-Benutzer (Standard: ${RDP_USER})
  --web-password <pw>    Passwort der Web UI (Standard: generiert)
  --rdp-password <pw>    Passwort für RDP/Samba (Standard: generiert)
  --root-password <pw>   Root-Passwort des Containers (Standard: gesperrt)
  --local-dir <path>     Lokalen Repo-Checkout statt GitHub verwenden
  --check                Nur einen bestehenden Container prüfen
  --uninstall            Container löschen (braucht --id)
  --dry-run              Nur planen, nichts ändern
  --debug                bash -x Log unter /root ablegen
  -y, --yes              Keine Rückfragen
  -h, --help             Diese Hilfe

Beispiele:
  ... | bash -s -- --id 121
  ... | bash -s -- --ip 192.168.1.50/24 --gw 192.168.1.1 --ram 4096
  ... | bash -s -- --uninstall --id 121
EOF
}

on_error() {
  local rc=$? i
  set +e
  {
    printf '\n%s\n' "================ INSTALLER FAILED ================"
    printf 'exit code  : %s\n' "$rc"
    printf 'line       : %s\n' "${BASH_LINENO[0]:-unknown}"
    printf 'command    : %s\n' "${BASH_COMMAND:-unknown}"
    printf 'function   : %s\n' "${FUNCNAME[1]:-main}"
    printf 'call stack :\n'
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      printf '   at %s (%s:%s)\n' \
        "${FUNCNAME[$i]}" "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$i - 1]:-?}"
    done
    if [[ -n "${CT_ID:-}" ]]; then
      printf '\n--- pct status %s ---\n' "$CT_ID"
      pct status "$CT_ID" 2>&1 || true
      printf '\n--- Container-Installationslog (letzte 80 Zeilen) ---\n'
      pct exec "$CT_ID" -- tail -n 80 /var/log/proton-download-box-install.log 2>&1 || true
      printf '\n--- systemctl status (Container) ---\n'
      pct exec "$CT_ID" -- systemctl status "${APP_NAME}" --no-pager -l 2>&1 | tail -n 30 || true
    fi
    printf '\nHinweis: für einen vollständigen Trace erneut mit --debug starten.\n'
    printf '%s\n' "=================================================="
  } >&2
  exit "$rc"
}
trap on_error ERR

cleanup() {
  [[ -n "${PAYLOAD_TAR:-}" && -f "${PAYLOAD_TAR:-}" ]] && rm -f "$PAYLOAD_TAR"
  [[ -n "${PAYLOAD_TMP:-}" && -d "${PAYLOAD_TMP:-}" ]] && rm -rf "$PAYLOAD_TMP"
  [[ -n "${INSTALL_ENV:-}" && -f "${INSTALL_ENV:-}" ]] && rm -f "$INSTALL_ENV"
  return 0
}
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# argument parsing
# --------------------------------------------------------------------------- #

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) CT_ID="${2:?--id braucht einen Wert}"; shift 2 ;;
    --hostname) CT_HOSTNAME="${2:?}"; shift 2 ;;
    --cores) CORES="${2:?}"; shift 2 ;;
    --ram) RAM_MB="${2:?}"; shift 2 ;;
    --swap) SWAP_MB="${2:?}"; shift 2 ;;
    --disk) DISK_GB="${2:?}"; shift 2 ;;
    --storage) STORAGE="${2:?}"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="${2:?}"; shift 2 ;;
    --bridge) BRIDGE="${2:?}"; shift 2 ;;
    --ip) IP_CONFIG="${2:?}"; shift 2 ;;
    --gw) GATEWAY="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --tz) TZ_VALUE="${2:?}"; shift 2 ;;
    --kbd) KBD_LAYOUT="${2:?}"; shift 2 ;;
    --rdp-user) RDP_USER="${2:?}"; shift 2 ;;
    --web-password) WEB_PASSWORD="${2:?}"; shift 2 ;;
    --rdp-password) RDP_PASSWORD="${2:?}"; shift 2 ;;
    --root-password) ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --local-dir) LOCAL_DIR="${2:?}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

if [[ $DEBUG -eq 1 ]]; then
  DEBUG_LOG="/root/${APP_NAME}-debug-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$DEBUG_LOG") 2>&1
  PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}() '
  set -x
  msg "Debug-Log: $DEBUG_LOG"
fi

# --------------------------------------------------------------------------- #
# validation
# --------------------------------------------------------------------------- #

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
  die "Ungültiger Port: $PORT"
fi
if [[ ! "$CORES" =~ ^[0-9]+$ ]] || ((CORES < 1)); then
  die "Ungültige Core-Anzahl: $CORES"
fi
if [[ ! "$RAM_MB" =~ ^[0-9]+$ ]] || ((RAM_MB < 1024)); then
  die "RAM muss >= 1024 MB sein"
fi
if [[ ! "$DISK_GB" =~ ^[0-9]+$ ]] || ((DISK_GB < 8)); then
  die "Disk muss >= 8 GB sein"
fi
[[ "$SWAP_MB" =~ ^[0-9]+$ ]] || die "Ungültiger Swap-Wert: $SWAP_MB"
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
  || die "Ungültiger Hostname: $CT_HOSTNAME"
if [[ -n "$CT_ID" ]]; then
  if [[ ! "$CT_ID" =~ ^[0-9]+$ ]] || ((CT_ID < 100 || CT_ID > 999)); then
    die "CT-ID muss zwischen 100 und 999 liegen"
  fi
fi
if [[ "$IP_CONFIG" != "dhcp" ]]; then
  [[ "$IP_CONFIG" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
    || die "Ungültige IP: $IP_CONFIG (erwartet z. B. 192.168.1.50/24)"
fi

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

gen_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '/+=' | cut -c1-20
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
  fi
}

id_in_use() {
  local id=$1
  pct config "$id" >/dev/null 2>&1 && return 0
  command -v qm >/dev/null 2>&1 && qm config "$id" >/dev/null 2>&1 && return 0
  return 1
}

next_free_id() {
  local id
  for ((id = 100; id < 1000; id++)); do
    if ! id_in_use "$id"; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

pick_storage() {
  local content=$1 requested=$2
  if [[ -n "$requested" ]]; then
    if ! pvesm status -content "$content" -storage "$requested" >/dev/null 2>&1; then
      die "Storage '$requested' unterstützt keinen Inhalt vom Typ '$content'."
    fi
    printf '%s\n' "$requested"
    return 0
  fi
  pvesm status -content "$content" 2>/dev/null \
    | awk 'NR > 1 && $3 == "active" { print $1; exit }'
}

ensure_template() {
  local template
  template=$(pveam available --section system 2>/dev/null \
    | awk '/debian-12-standard/ { print $2 }' | sort -V | tail -n1)
  [[ -n "$template" ]] || die "Kein debian-12-standard Template gefunden. Bitte 'pveam update' ausführen."

  # Wichtig: alle Meldungen nach stderr – stdout muss exakt den Template-Pfad
  # liefern, da diese Funktion per Command-Substitution ausgewertet wird.
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{ print $1 }' \
      | grep -qx "${TEMPLATE_STORAGE}:vztmpl/${template}"; then
    msg "LXC-Template herunterladen: $template → $TEMPLATE_STORAGE" >&2
    pveam download "$TEMPLATE_STORAGE" "$template" >&2
  else
    ok "Template bereits vorhanden: $template" >&2
  fi

  printf '%s\n' "${TEMPLATE_STORAGE}:vztmpl/${template}"
}

wait_for_ct() {
  local i
  for ((i = 1; i <= 60; i++)); do
    if pct exec "$CT_ID" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_network() {
  local i
  for ((i = 1; i <= 90; i++)); do
    if pct exec "$CT_ID" -- bash -c 'getent hosts deb.debian.org >/dev/null 2>&1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_dpkg() {
  # [a]pt/[d]pkg-Klammer-Trick: verhindert, dass pgrep die eigene
  # Kommandozeile (mit dem Pattern-Text) matcht.
  pct exec "$CT_ID" -- bash -c '
    for i in {1..60}; do
      if ! pgrep -f "[a]pt-get|[d]pkg" >/dev/null 2>&1; then exit 0; fi
      sleep 2
    done
    exit 1
  ' >/dev/null 2>&1 || warn "dpkg-Lock war lange belegt – fahre trotzdem fort"
}

ct_ip() {
  pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{ print $1 }'
}

# --------------------------------------------------------------------------- #
# preflight
# --------------------------------------------------------------------------- #

has_pve_tools() {
  command -v pct >/dev/null 2>&1 && command -v pveam >/dev/null 2>&1 \
    && command -v pvesm >/dev/null 2>&1 && [[ -d "$PVE_ETC" ]]
}

# Nur für echte Änderungen root + Proxmox-Werkzeuge verlangen. So funktionieren
# --help und --dry-run auch auf anderen Rechnern.
if [[ $DRY_RUN -eq 0 ]]; then
  [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – bitte auf dem Proxmox-Host ausführen."
  command -v pveam >/dev/null 2>&1 || die "pveam nicht gefunden – bitte auf dem Proxmox-Host ausführen."
  command -v pvesm >/dev/null 2>&1 || die "pvesm nicht gefunden – bitte auf dem Proxmox-Host ausführen."
  [[ -d "$PVE_ETC" ]] || die "${PVE_ETC} fehlt – kein Proxmox-Host?"
  command -v curl >/dev/null 2>&1 || die "curl fehlt (apt-get install -y curl)"
fi

if [[ $UNINSTALL -eq 1 ]]; then
  command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – ist das ein Proxmox-Host?"
  [[ -n "$CT_ID" ]] || die "--uninstall benötigt --id <CT-ID>"
  pct config "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID existiert nicht"
  if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "CT $CT_ID ($(pct config "$CT_ID" | sed -n 's/^hostname: //p')) wirklich löschen? [y/N] " answer
    [[ "$answer" =~ ^[yY]$ ]] || die "Abgebrochen"
  fi
  msg "Container $CT_ID wird entfernt"
  pct stop "$CT_ID" >/dev/null 2>&1 || true
  pct destroy "$CT_ID" --purge
  ok "Container $CT_ID entfernt"
  exit 0
fi

if [[ $DRY_RUN -eq 0 && $CHECK_ONLY -eq 0 ]]; then
  command -v curl >/dev/null 2>&1 || die "curl fehlt (apt-get install -y curl)"
fi

if [[ -z "$CT_ID" ]]; then
  CT_ID=$(next_free_id) || die "Keine freie CT-ID zwischen 100 und 999 gefunden."
  ok "Nächste freie CT-ID: $CT_ID"
fi

if [[ $CHECK_ONLY -eq 0 ]]; then
  STORAGE=$(pick_storage rootdir "$STORAGE")
  [[ -n "$STORAGE" ]] || die "Kein aktiver Storage für Container-Disks gefunden (--storage angeben)."
  TEMPLATE_STORAGE=$(pick_storage vztmpl "$TEMPLATE_STORAGE")
  [[ -n "$TEMPLATE_STORAGE" ]] || die "Kein aktiver Storage für Templates gefunden (--template-storage angeben)."
  ok "Storage: rootfs=$STORAGE, templates=$TEMPLATE_STORAGE"
fi

# --------------------------------------------------------------------------- #
# existing container?
# --------------------------------------------------------------------------- #

if pct config "$CT_ID" >/dev/null 2>&1; then
  if pct config "$CT_ID" | grep -q 'description:.*proton-download-box' \
    || pct exec "$CT_ID" -- test -f /etc/proton-download-box.env >/dev/null 2>&1; then
    REUSE=1
    ok "Bestehende Installation in CT $CT_ID erkannt – Update-Modus"
  else
    die "CT $CT_ID existiert, gehört aber nicht zu ${APP_NAME}. Bitte andere --id wählen."
  fi
elif id_in_use "$CT_ID"; then
  die "ID $CT_ID ist bereits von einer VM belegt. Bitte andere --id wählen."
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  [[ $REUSE -eq 1 ]] || die "CT $CT_ID enthält keine ${APP_NAME}-Installation."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\n%s\n' "${C_C}Dry-Run – geplante Konfiguration${C_0}"
  printf '  CT-ID        : %s\n' "$CT_ID"
  printf '  Hostname     : %s\n' "$CT_HOSTNAME"
  printf '  Ressourcen   : %s vCPU / %s MB RAM / %s MB Swap / %s GB Disk\n' "$CORES" "$RAM_MB" "$SWAP_MB" "$DISK_GB"
  printf '  Storage      : %s (Templates: %s)\n' "${STORAGE:-auto}" "${TEMPLATE_STORAGE:-auto}"
  printf '  Netzwerk     : %s, bridge %s, gw %s\n' "$IP_CONFIG" "$BRIDGE" "${GATEWAY:-auto}"
  printf '  Web UI       : Port %s, Benutzer %s (RDP), Zeitzone %s\n' "$PORT" "$RDP_USER" "$TZ_VALUE"
  printf '  Modus        : %s\n' "$([[ $REUSE -eq 1 ]] && echo Update || echo Neuinstallation)"
  exit 0
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  if [[ "$(pct status "$CT_ID" 2>/dev/null)" != *running* ]]; then
    msg "Container $CT_ID starten"
    pct start "$CT_ID"
    wait_for_ct || die "Container $CT_ID startet nicht"
  fi
  verify
  printf '\n%sCheck OK: http://%s:%s%s\n\n' "$C_G" "$CT_IP" "$PORT" "$C_0"
  exit 0
fi

for secret in "$WEB_PASSWORD" "$RDP_PASSWORD"; do
  [[ "$secret" != *"'"* && "$secret" != *$'\n'* ]] \
    || die "Passwörter dürfen keine einfachen Anführungszeichen oder Zeilenumbrüche enthalten."
done

# --------------------------------------------------------------------------- #
# payload
# --------------------------------------------------------------------------- #

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
fi

prepare_payload() {
  local src=""

  if [[ -n "$LOCAL_DIR" ]]; then
    src="$(cd -- "$LOCAL_DIR" >/dev/null 2>&1 && pwd)" || die "Lokales Verzeichnis nicht gefunden: $LOCAL_DIR"
    msg "Payload aus lokalem Verzeichnis: $src"
  elif [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../scripts/install-inside.sh" ]]; then
    src="$(cd -- "$SCRIPT_DIR/.." && pwd)"
    msg "Payload aus lokalem Checkout: $src"
  else
    [[ "$GITHUB_REPO" != "USER/REPO" ]] \
      || die "GitHub-Repo ist noch der Platzhalter 'USER/REPO'. Bitte in install/${APP_NAME}.sh ersetzen oder --local-dir nutzen."
    msg "Payload von GitHub laden: ${GITHUB_REPO}@${GITHUB_REF}"
    PAYLOAD_TMP=$(mktemp -d /tmp/${APP_NAME}.XXXXXX)
    local dirs=()

    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$PAYLOAD_TMP/repo.tar.gz" "$REPO_TARBALL"; then
      die "Download fehlgeschlagen: $REPO_TARBALL (Repo/Ref prüfen)"
    fi
    tar -xzf "$PAYLOAD_TMP/repo.tar.gz" -C "$PAYLOAD_TMP"
    mapfile -t dirs < <(find "$PAYLOAD_TMP" -maxdepth 1 -mindepth 1 -type d)
    ((${#dirs[@]} > 0)) || die "Tarball enthält kein Verzeichnis"
    src="${dirs[0]}"

    # Veralteter CDN-Cache? Dann über die GitHub-API frisch nachladen –
    # sonst installiert man unbemerkt eine alte Version.
    local ver=""
    ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$src/scripts/install-inside.sh" | head -n1)
    if [[ -n "$ver" && "$ver" != "$EXPECTED_SCRIPT_VERSION" ]]; then
      warn "Payload veraltet ($ver statt $EXPECTED_SCRIPT_VERSION) – lade über GitHub-API neu"
      rm -rf "${PAYLOAD_TMP:?}"/*
      dirs=()
      if curl -fsSL --retry 3 --retry-delay 2 -o "$PAYLOAD_TMP/repo.tar.gz" \
           "https://api.github.com/repos/${GITHUB_REPO}/tarball/${GITHUB_REF}"; then
        tar -xzf "$PAYLOAD_TMP/repo.tar.gz" -C "$PAYLOAD_TMP"
        mapfile -t dirs < <(find "$PAYLOAD_TMP" -maxdepth 1 -mindepth 1 -type d)
        ((${#dirs[@]} > 0)) && src="${dirs[0]}"
      else
        warn "API-Download fehlgeschlagen – nutze die (ältere) Version $ver"
      fi
    fi
  fi

  [[ -f "$src/scripts/install-inside.sh" ]] || die "Payload unvollständig: $src/scripts/install-inside.sh fehlt"
  [[ -f "$src/app/backend/main.py" ]] || die "Payload unvollständig: $src/app/backend/main.py fehlt"
  [[ -d "$src/app/frontend/dist" ]] || die "Frontend-Build fehlt: $src/app/frontend/dist (npm run build)"
  [[ -f "$src/config/${APP_NAME}.service" ]] || die "Payload unvollständig: systemd-Unit fehlt"

  PAYLOAD_TAR=$(mktemp /tmp/${APP_NAME}-payload.XXXXXX.tar.gz)
  tar -czf "$PAYLOAD_TAR" -C "$src" \
    --exclude='app/frontend/node_modules' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    scripts app config
  ok "Payload gepackt ($(du -h "$PAYLOAD_TAR" | cut -f1))"
  # Zeigt die tatsächlich geladene Payload-Version – damit ein veralteter
  # GitHub-Cache sofort auffällt.
  local payload_ver
  payload_ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$src/scripts/install-inside.sh" 2>/dev/null | head -n1)
  PAYLOAD_VERSION="${payload_ver:-unbekannt}"
  ok "Payload-Version: $PAYLOAD_VERSION (erwartet: $EXPECTED_SCRIPT_VERSION)"
}

# --------------------------------------------------------------------------- #
# create container
# --------------------------------------------------------------------------- #

create_container() {
  local template net0
  template=$(ensure_template)

  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth"
  if [[ "$IP_CONFIG" != "dhcp" && -n "$GATEWAY" ]]; then
    net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},gw=${GATEWAY},type=veth"
  fi

  msg "Container $CT_ID (${CT_HOSTNAME}) wird erstellt"
  local args=(
    "$CT_ID" "$template"
    --hostname "$CT_HOSTNAME"
    --cores "$CORES"
    --memory "$RAM_MB"
    --swap "$SWAP_MB"
    --rootfs "${STORAGE}:${DISK_GB}"
    --net0 "$net0"
    --unprivileged 1
    --features "nesting=1,keyctl=1"
    --onboot 1
    --ostype debian
    --description "${APP_NAME}: ${APP_DESC}"
  )
  [[ -n "$ROOT_PASSWORD" ]] && args+=(--password "$ROOT_PASSWORD")

  pct create "${args[@]}"
  ok "Container angelegt"

  # Proton needs a TUN device for OpenVPN fallback / the kill switch.
  if modprobe tun 2>/dev/null || [[ -e /dev/net/tun ]]; then
    local conf="${PVE_ETC}/lxc/${CT_ID}.conf"
    if ! grep -q 'dev/net/tun' "$conf"; then
      {
        printf '# proton-download-box: TUN für Proton VPN\n'
        printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\n'
        printf 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file,optional 0 0\n'
      } >>"$conf"
    fi
    ok "/dev/net/tun durchgereicht"
  else
    warn "/dev/net/tun nicht verfügbar – Proton VPN ggf. nur mit WireGuard nutzbar"
  fi

  msg "Container starten"
  pct start "$CT_ID"
}

# --------------------------------------------------------------------------- #
# install / update inside the container
# --------------------------------------------------------------------------- #

run_inside() {
  msg "Auf Container wartet"
  wait_for_ct || die "Container $CT_ID antwortet nicht"
  wait_for_network || warn "DNS im Container noch nicht bereit – apt könnte langsam sein"
  wait_for_dpkg

  msg "Payload in den Container kopieren"
  pct push "$CT_ID" "$PAYLOAD_TAR" /root/pdb-payload.tar.gz
  pct exec "$CT_ID" -- bash -c \
    'rm -rf /root/pdb-payload && mkdir -p /root/pdb-payload && tar -xzf /root/pdb-payload.tar.gz -C /root/pdb-payload'
  ok "Payload entpackt"

  INSTALL_ENV=$(mktemp /tmp/${APP_NAME}-env.XXXXXX)
  umask 077
  cat >"$INSTALL_ENV" <<EOF
PDB_PORT='${PORT}'
PDB_CT_ID='${CT_ID}'
PDB_TZ='${TZ_VALUE}'
PDB_KBD_LAYOUT='${KBD_LAYOUT}'
PDB_PASSWORD='${WEB_PASSWORD}'
PDB_RDP_USER='${RDP_USER}'
PDB_RDP_PASSWORD='${RDP_PASSWORD}'
PDB_SMB_USER='${RDP_USER}'
PDB_SMB_PASSWORD='${RDP_PASSWORD}'
EOF
  umask 022   # zurücksetzen: pct exec / lxc-attach erbt die umask im Container!
  pct push "$CT_ID" "$INSTALL_ENV" /root/pdb-install.env

  msg "Installation im Container läuft (das dauert einige Minuten)"
  pct exec "$CT_ID" -- bash -c \
    'set -a; . /root/pdb-install.env; set +a; bash /root/pdb-payload/scripts/install-inside.sh'
  pct exec "$CT_ID" -- rm -f /root/pdb-install.env >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------- #
# verify
# --------------------------------------------------------------------------- #

verify() {
  msg "Installation verifizieren"
  pct exec "$CT_ID" -- systemctl is-active --quiet "${APP_NAME}" \
    || die "Service ${APP_NAME} ist im Container nicht aktiv"

  local ip="" i
  for ((i = 1; i <= 30; i++)); do
    ip=$(ct_ip)
    [[ -n "$ip" ]] && break
    sleep 1
  done
  [[ -n "$ip" ]] || die "Container-IP konnte nicht ermittelt werden"

  if ! curl -fsS --max-time 10 "http://${ip}:${PORT}/api/health" >/dev/null 2>&1; then
    warn "Web UI über ${ip}:${PORT} nicht erreichbar – Container-Firewall wird deaktiviert"
    pct exec "$CT_ID" -- bash -c 'nft flush ruleset 2>/dev/null; systemctl disable nftables 2>/dev/null' || true
    curl -fsS --max-time 10 "http://${ip}:${PORT}/api/health" >/dev/null 2>&1 \
      || die "Web UI antwortet nicht auf http://${ip}:${PORT}/api/health"
    warn "Firewall im Container wurde deaktiviert (Ports bleiben über Proxmox-Firewall regelbar)"
  fi
  ok "Web UI antwortet auf http://${ip}:${PORT}"

  CT_IP="$ip"
}

# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

msg "${APP_TITLE} – Installation auf Proxmox VE"
printf '  CT-ID: %s · Hostname: %s · Ressourcen: %s vCPU / %s MB RAM / %s GB Disk\n' \
  "$CT_ID" "$CT_HOSTNAME" "$CORES" "$RAM_MB" "$DISK_GB"

prepare_payload

if [[ $REUSE -eq 0 ]]; then
  create_container
else
  if [[ "$(pct status "$CT_ID" 2>/dev/null)" != *running* ]]; then
    msg "Container $CT_ID starten"
    pct start "$CT_ID"
    wait_for_ct || die "Container $CT_ID startet nicht"
  fi
  # Preserve existing secrets on updates.
  if [[ -z "$WEB_PASSWORD" ]]; then
    WEB_PASSWORD=$(pct exec "$CT_ID" -- sed -n 's/^PDB_PASSWORD=//p' /etc/proton-download-box.env 2>/dev/null | head -n1 || true)
  fi
  if [[ -z "$RDP_PASSWORD" ]]; then
    RDP_PASSWORD=$(pct exec "$CT_ID" -- sed -n 's/^RDP_PASSWORD=//p' /root/proton-download-box-credentials.txt 2>/dev/null | head -n1 || true)
  fi
fi

[[ -n "$WEB_PASSWORD" ]] || WEB_PASSWORD=$(gen_pass)
[[ -n "$RDP_PASSWORD" ]] || RDP_PASSWORD=$(gen_pass)

run_inside
verify

# --------------------------------------------------------------------------- #
# summary
# --------------------------------------------------------------------------- #

printf '\n%s\n' "${C_G}${C_B}════════════════════════════════════════════════════════════════${C_0}"
printf '%s\n' "${C_G}${C_B} ${APP_TITLE} ist bereit${C_0}"
printf '%s\n' "${C_G}${C_B}════════════════════════════════════════════════════════════════${C_0}"
printf '  Container     : %s (%s), onboot=1\n' "$CT_ID" "$CT_HOSTNAME"
printf '  Web UI        : %shttp://%s:%s%s\n' "$C_C" "$CT_IP" "$PORT" "$C_0"
printf '  Web-Passwort  : %s\n' "$WEB_PASSWORD"
printf '  RDP-Desktop   : %s%s:3389%s  (Benutzer %s)\n' "$C_C" "$CT_IP" "$C_0" "$RDP_USER"
printf '  RDP-Passwort  : %s\n' "$RDP_PASSWORD"
printf '  Samba         : \\\\%s\\downloads  (Benutzer %s, gleiches Passwort)\n' "$CT_IP" "$RDP_USER"
printf '  Dateien       : /srv/downloads\n'
printf '  Container-Shell: pct enter %s\n' "$CT_ID"
printf '\n'
printf '  Nächster Schritt:\n'
printf '    1. Per RDP mit %s auf %s verbinden\n' "$RDP_USER" "$CT_IP"
printf '    2. Proton VPN starten, mit dem kostenlosen Account anmelden\n'
printf '    3. Server verbinden und in den Einstellungen den Killswitch aktivieren\n'
printf '    4. Downloads über die Web UI oder Samba abholen\n'
printf '\n'
printf '  Update:     Installer erneut mit --id %s ausführen\n' "$CT_ID"
printf '  Deinstall:  ... | bash -s -- --uninstall --id %s\n' "$CT_ID"
printf '  Logs:       pct exec %s -- journalctl -u %s -f\n' "$CT_ID" "$APP_NAME"
printf '%s\n' "════════════════════════════════════════════════════════════════"
printf '\n'
