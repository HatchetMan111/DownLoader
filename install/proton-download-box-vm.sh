#!/usr/bin/env bash
# =============================================================================
#  proton-download-box – VM-Installer (Proxmox VE)
#
#  Erstellt eine Debian-12-VM per Cloud-Image und richtet dort dieselbe
#  Download-Box ein wie im LXC-Modus (Web-UI, Dateimanager, Samba, xrdp).
#
#  Warum VM? Proton VPN baut seine Verbindung über NetworkManager auf und
#  benötigt dabei Kernel-/Session-Funktionen, die ein unprivilegierter LXC
#  nicht zuverlässig bereitstellt. In einer VM läuft alles nativ.
#
#  Aufruf (root auf dem Proxmox-Host):
#     bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/proton-download-box-vm.sh)"
#
#  Optionen: --id, --ram, --cores, --disk, --storage, --bridge, --port,
#            --tz, --kbd, --password, --dry-run, -y
# =============================================================================
set -Eeuo pipefail

APP_NAME="proton-download-box"
GITHUB_REPO="${PDB_GITHUB_REPO:-HatchetMan111/DownLoader}"
GITHUB_REF="${PDB_GITHUB_REF:-main}"
REPO_TARBALL="https://codeload.github.com/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_REF}"
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
CLOUD_IMAGE="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"

VM_ID=""
VM_NAME="proton-download-box"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
DISK_GB="${DISK_GB:-16}"
STORAGE="${STORAGE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
PORT="${PORT:-8080}"
TZ_VALUE="${TZ_VALUE:-Europe/Berlin}"
KBD_LAYOUT="${KBD_LAYOUT:-de}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
DRY_RUN=0

C_B=$'\033[1m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
msg()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  xx%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

on_error() {
  local rc=$? i
  set +e
  {
    printf '\n================ VM-INSTALLATION FEHLGESCHLAGEN ================\n'
    printf 'exit code : %s\n' "$rc"
    printf 'line      : %s\n' "${BASH_LINENO[0]:-?}"
    printf 'command   : %s\n' "${BASH_COMMAND:-?}"
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      printf '   at %s (%s:%s)\n' "${FUNCNAME[$i]}" "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$i-1]:-?}"
    done
    if [[ -n "${VM_ID:-}" ]]; then
      printf '\n--- qm status ---\n'; qm status "$VM_ID" 2>&1 || true
      printf '\n--- VM-Konfiguration ---\n'; qm config "$VM_ID" 2>&1 | head -n 25 || true
    fi
    printf '\nHinweis: Cloud-Init läuft beim ersten Boot. Log im Gast:\n'
    printf '   qm terminal %s   (root-Login) →  tail -f /var/log/pdb-install.log\n' "${VM_ID:-<ID>}"
    printf '%s\n' "================================================================"
  } >&2
  exit "$rc"
}
trap on_error ERR

usage() {
  cat <<EOF
${C_B}${APP_NAME} – VM-Installer${C_0}

  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}/install/${APP_NAME}-vm.sh)"

  --id <100-999>    VM-ID (Standard: nächste freie)
  --name <name>     VM-Name (Standard: ${VM_NAME})
  --cores <n>       vCPUs (Standard: ${CORES})
  --ram <mb>        RAM (Standard: ${RAM_MB})
  --disk <gb>       Disk (Standard: ${DISK_GB})
  --storage <n>     Storage für die VM-Disk (Standard: automatisch)
  --bridge <n>      Bridge (Standard: ${BRIDGE})
  --port <port>     Web-UI-Port (Standard: ${PORT})
  --tz <zone>       Zeitzone (Standard: ${TZ_VALUE})
  --kbd <layout>    Tastatur im Desktop (Standard: ${KBD_LAYOUT})
  --password <pw>   Root-Passwort der VM (Standard: generiert)
  --dry-run         Nur anzeigen
  -y, --yes         Keine Rückfragen
  -h, --help        Hilfe
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) VM_ID="${2:?}"; shift 2 ;;
    --name) VM_NAME="${2:?}"; shift 2 ;;
    --cores) CORES="${2:?}"; shift 2 ;;
    --ram) RAM_MB="${2:?}"; shift 2 ;;
    --disk) DISK_GB="${2:?}"; shift 2 ;;
    --storage) STORAGE="${2:?}"; shift 2 ;;
    --bridge) BRIDGE="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --tz) TZ_VALUE="${2:?}"; shift 2 ;;
    --kbd) KBD_LAYOUT="${2:?}"; shift 2 ;;
    --password) ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

gen_pass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-20; }

id_in_use() {
  local id=$1
  qm config "$id" >/dev/null 2>&1 && return 0
  pct config "$id" >/dev/null 2>&1 && return 0
  return 1
}

next_free_id() {
  local id
  for ((id = 100; id < 1000; id++)); do
    id_in_use "$id" || { printf '%s\n' "$id"; return 0; }
  done
  return 1
}

pick_storage() {
  local content=$1
  pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
}

[[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v qm >/dev/null || die "qm nicht gefunden – ist das ein Proxmox-Host?"
[[ -d /etc/pve ]] || die "/etc/pve fehlt – kein Proxmox-Host?"

[[ -n "$VM_ID" ]] || VM_ID=$(next_free_id) || die "Keine freie ID gefunden"
id_in_use "$VM_ID" && die "ID $VM_ID ist bereits belegt"

[[ -n "$ROOT_PASSWORD" ]] || ROOT_PASSWORD=$(gen_pass)
TARGET_PASSWORD="${TARGET_PASSWORD:-$(gen_pass)}"
RDP_PASSWORD="${RDP_PASSWORD:-$(gen_pass)}"

if [[ -z "$STORAGE" ]]; then
  STORAGE=$(pick_storage images)
  [[ -n "$STORAGE" ]] || die "Kein Storage für VM-Images (--storage angeben)"
fi

SNIPPET_STORAGE="${SNIPPET_STORAGE:-$(pick_storage snippets)}"
[[ -n "$SNIPPET_STORAGE" ]] || die "Kein Storage mit Inhalt 'snippets'.
Aktivieren unter: Datacenter → Storage → <storage> → Inhalte → Snippets"

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\n%s\n' "${C_B}Dry-Run${C_0}"
  printf '  VM-ID      : %s\n  Name       : %s\n  Ressourcen : %s vCPU / %s MB RAM / %s GB\n' \
    "$VM_ID" "$VM_NAME" "$CORES" "$RAM_MB" "$DISK_GB"
  printf '  Storage    : %s (Snippets: %s)\n  Netzwerk   : %s\n  Port       : %s\n' \
    "$STORAGE" "$SNIPPET_STORAGE" "$BRIDGE" "$PORT"
  exit 0
fi

# --- Cloud-Image -------------------------------------------------------------
if [[ ! -f "$CLOUD_IMAGE" ]]; then
  msg "Debian-12-Cloud-Image laden (~350 MB)"
  mkdir -p "$(dirname "$CLOUD_IMAGE")"
  curl -fL --retry 3 -o "$CLOUD_IMAGE.part" "$CLOUD_IMAGE_URL" || die "Download fehlgeschlagen"
  mv "$CLOUD_IMAGE.part" "$CLOUD_IMAGE"
fi
ok "Cloud-Image vorhanden: $CLOUD_IMAGE"

# --- Cloud-Init: alles im Gast einrichten ------------------------------------
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"
USERDATA="$SNIPPET_DIR/${APP_NAME}-${VM_ID}.yaml"

cat >"$USERDATA" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
ssh_pwauth: true
packages:
  - qemu-guest-agent
write_files:
  - path: /root/pdb-run.sh
    permissions: '0700'
    content: |
      #!/bin/bash
      exec > /var/log/pdb-install.log 2>&1
      set -x
      mkdir -p /root/pdb
      curl -fsSL '${REPO_TARBALL}' | tar -xz -C /root/pdb --strip-components=1
      export PDB_PORT='${PORT}'
      export PDB_TZ='${TZ_VALUE}'
      export PDB_PASSWORD='${TARGET_PASSWORD}'
      export PDB_RDP_USER='proton'
      export PDB_RDP_PASSWORD='${RDP_PASSWORD}'
      export PDB_SMB_USER='proton'
      export PDB_SMB_PASSWORD='${RDP_PASSWORD}'
      export PDB_KBD_LAYOUT='${KBD_LAYOUT}'
      export PDB_CT_ID='${VM_ID}'
      export PDB_VM='1'
      bash /root/pdb/scripts/install-inside.sh
runcmd:
  - [ bash, /root/pdb-run.sh ]
EOF
chmod 0600 "$USERDATA"
ok "Cloud-Init-Datei: $USERDATA"

# --- VM anlegen --------------------------------------------------------------
msg "VM $VM_ID ($VM_NAME) erstellen"
qm create "$VM_ID" \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --cores "$CORES" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --ostype l26 \
  --agent enabled=1 \
  --onboot 1 \
  --serial0 socket \
  --vga serial0

qm importdisk "$VM_ID" "$CLOUD_IMAGE" "$STORAGE" >/dev/null
qm set "$VM_ID" --scsi0 "${STORAGE}:vm-${VM_ID}-disk-0" --boot order=scsi0 >/dev/null
qm set "$VM_ID" --ide2 "${STORAGE}:cloudinit" >/dev/null
qm resize "$VM_ID" scsi0 "${DISK_GB}G" >/dev/null
qm set "$VM_ID" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$USERDATA")" >/dev/null
qm set "$VM_ID" --ciuser root --cipassword "$ROOT_PASSWORD" --ipconfig0 ip=dhcp >/dev/null
ok "VM konfiguriert (Cloud-Init)"

msg "VM starten"
qm start "$VM_ID"

# --- IP ermitteln ------------------------------------------------------------
MAC=$(qm config "$VM_ID" | sed -n 's/^net0:.*virtio=\([^,]*\).*/\1/p')
[[ -n "$MAC" ]] || die "MAC-Adresse nicht ermittelbar"

msg "Warte auf Netzwerk der VM (Cloud-Init installiert jetzt alles)"
VM_IP=""
for _ in $(seq 1 150); do
  sleep 2

  # 1) Bevorzugt: Guest-Agent (zuverlässig, sobald das Paket installiert ist)
  if command -v jq >/dev/null 2>&1; then
    VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null \
      | jq -r '.[]? | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type"=="ipv4") | ."ip-address"' 2>/dev/null \
      | grep -v '^127\.' | head -n1)
  fi

  # 2) Fallback: ARP-Tabelle über die MAC-Adresse
  if [[ -z "$VM_IP" ]]; then
    VM_IP=$(ip neigh 2>/dev/null | awk -v m="$MAC" '
      { for (i = 1; i <= NF; i++) if ($i == "lladdr" && tolower($(i+1)) == tolower(m)) { print $1; exit } }')
  fi

  [[ -n "$VM_IP" && "$VM_IP" != "0.0.0.0" ]] && break
  VM_IP=""
done

if [[ -z "$VM_IP" ]]; then
  warn "Keine IP ermittelbar. Diagnose:"
  printf '  qm status %s: %s\n' "$VM_ID" "$(qm status "$VM_ID" 2>&1)"
  printf '  MAC laut Proxmox: %s\n' "$MAC"
  printf '  ARP-Tabelle:\n'; ip neigh 2>/dev/null | sed 's/^/    /' | head -n 10
  printf '\n  Konsole öffnen:  qm terminal %s\n' "$VM_ID"
  printf '  Nach dem Login:  cat /var/log/pdb-install.log\n\n'
  die "VM ohne IP – bitte obige Diagnose prüfen"
fi
ok "VM-IP: $VM_IP"

msg "Warte auf Web-UI (Installation im Gast läuft, 5–15 Minuten)"
READY=0
for _ in $(seq 1 300); do
  if curl -fsS --max-time 3 "http://${VM_IP}:${PORT}/api/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

if [[ $READY -ne 1 ]]; then
  warn "Web-UI noch nicht erreichbar. Installation läuft evtl. noch."
  printf '\n  Log ansehen:   qm terminal %s   →  tail -f /var/log/pdb-install.log\n' "$VM_ID"
  printf '  Später prüfen: curl http://%s:%s/api/health\n\n' "$VM_IP" "$PORT"
  exit 0
fi

ok "Web UI antwortet: http://${VM_IP}:${PORT}"

printf '\n%s\n' "${C_G}${C_B}════════════════════════════════════════════════════════════════${C_0}"
printf '%s\n' "${C_G}${C_B} ${APP_NAME} (VM) ist bereit${C_0}"
printf '%s\n' "${C_G}${C_B}════════════════════════════════════════════════════════════════${C_0}"
printf '  VM            : %s (%s), onboot=1\n' "$VM_ID" "$VM_NAME"
printf '  Web UI        : %shttp://%s:%s%s\n' "$C_G" "$VM_IP" "$PORT" "$C_0"
printf '  Web-Passwort  : %s\n' "$TARGET_PASSWORD"
printf '  Root/VNC      : qm terminal %s   (Passwort: %s)\n' "$VM_ID" "$ROOT_PASSWORD"
printf '  RDP           : %s:3389  (Benutzer proton / %s)\n' "$VM_IP" "$RDP_PASSWORD"
printf '  Samba         : \\\\%s\\downloads  (proton / %s)\n' "$VM_IP" "$RDP_PASSWORD"
printf '  Install-Log   : qm terminal %s → tail -f /var/log/pdb-install.log\n' "$VM_ID"
printf '\n'
printf '  Nächster Schritt (Proton VPN, im Gast):\n'
printf '    qm terminal %s   → root-Login\n' "$VM_ID"
printf '    bash /usr/local/bin/pdb-proton-setup\n'
printf '\n'
printf '  Danach in der Web UI: VPN-Steuerung (Standort, Killswitch, Leak-Test)\n'
printf '%s\n' "════════════════════════════════════════════════════════════════"
printf '\n'