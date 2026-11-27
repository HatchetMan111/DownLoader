#!/usr/bin/env bash
# =============================================================================
#  pdb-keyring-session – persistente D-Bus-Session + entsperrter SecretService
#
#  Proton VPN speichert Sitzung UND VPN-Zugangsdaten im SecretService.
#  Ein gesperrter Keyring führt zum stillen Abbruch des Verbindungsaufbaus
#  ("KeyringLocked: Failed to unlock the collection!").
#
#  Dieses Skript startet eine Session-Bus-Instanz, entsperrt den
#  (passwortlosen) Login-Keyring, prüft die Funktion mit einem Testeintrag
#  und legt bei Bedarf eine frische Sammlung an. Die Umgebung wird nach
#  /run/pdb-keyring/env.sh geschrieben.
# =============================================================================
set -u

ENV_DIR="${PDB_KEYRING_ENV_DIR:-/run/pdb-keyring}"
ENV_FILE="$ENV_DIR/env.sh"
KEYRING_DIR="$HOME/.local/share/keyrings"
# Der Installer legt das RDP-Login-Passwort hier ab (nur für den Desktop-User
# lesbar). Der Keyring ist damit passwortgeschützt; headless muss dasselbe
# Passwort verwendet werden, sonst bleibt er gesperrt.
PASS_FILE="${PDB_KEYRING_PASS_FILE:-$HOME/.pdb-keyring-pass}"
KEYRING_PW=""
[[ -r "$PASS_FILE" ]] && KEYRING_PW=$(head -n1 "$PASS_FILE" 2>/dev/null)

mkdir -p "$ENV_DIR" 2>/dev/null || true
unset XDG_RUNTIME_DIR

# Alte Daemons dieser Sitzung beenden
pkill -f "gnome-keyring-daemon" >/dev/null 2>&1 || true

start_bus() {
  local out
  out=$(dbus-daemon --session --fork --print-address=1 --print-pid=1 2>/dev/null)
  DBUS_SESSION_BUS_ADDRESS=$(printf '%s\n' "$out" | sed -n '1p')
  DBUS_SESSION_BUS_PID=$(printf '%s\n' "$out" | sed -n '2p')
  export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]
}

unlock_keyring() {
  # Passwort aus der Installer-Datei (Fallback: leeres Passwort für einen
  # evtl. noch passwortlosen Alt-Keyring). %s\n füttert gnome-keyring-daemon
  # per stdin – so wird die Sammlung mit dem RDP-Passwort entsperrt.
  printf '%s\n' "$KEYRING_PW" | gnome-keyring-daemon --unlock --replace \
    --components=secrets 2>/dev/null
}

keyring_works() {
  command -v secret-tool >/dev/null 2>&1 || return 1
  printf 'probe' | secret-tool store --label=pdb-probe pdb probe \
    >/dev/null 2>&1 || return 1
  [[ "$(secret-tool lookup pdb probe 2>/dev/null)" == "probe" ]]
}

if ! start_bus; then
  echo "Session-Bus konnte nicht gestartet werden." >&2
  exit 1
fi

unlock_keyring

if ! keyring_works; then
  echo "Keyring gesperrt – lege frische, passwortlose Sammlung an." >&2
  pkill -f "gnome-keyring-daemon" >/dev/null 2>&1 || true
  rm -rf "$KEYRING_DIR"
  mkdir -p "$KEYRING_DIR"
  chmod 0700 "$KEYRING_DIR"
  unlock_keyring
fi

if keyring_works; then
  echo "Keyring entsperrt und einsatzbereit."
else
  echo "WARNUNG: Keyring weiterhin gesperrt – Proton-Verbindung ggf. blockiert." >&2
fi

{
  printf "export DBUS_SESSION_BUS_ADDRESS='%s'\n" "${DBUS_SESSION_BUS_ADDRESS:-}"
  printf "export GNOME_KEYRING_CONTROL='%s'\n" "${GNOME_KEYRING_CONTROL:-}"
  printf "export SSH_AUTH_SOCK='%s'\n" "${SSH_AUTH_SOCK:-}"
} >"$ENV_FILE"
chmod 0644 "$ENV_FILE" 2>/dev/null || true

exec sleep infinity