#!/usr/bin/env bash
# =============================================================================
#  pdb-keyring-session – persistente D-Bus-Session + SecretService
#
#  Proton VPN speichert Sitzung UND VPN-Zugangsdaten im SecretService
#  (gnome-keyring). Ohne dauerhaft laufenden Keyring bricht der
#  Verbindungsaufbau still ab ("Keyring ... error" / 5s-Timeout).
#
#  Dieses Skript startet eine Session-Bus-Instanz und den Keyring-Daemon
#  und schreibt die nötigen Umgebungsvariablen nach
#  /run/pdb-keyring/env.sh, damit alle Proton-Aufrufe dieselbe Session
#  benutzen.
# =============================================================================
set -u

ENV_DIR="${PDB_KEYRING_ENV_DIR:-/run/pdb-keyring}"
ENV_FILE="$ENV_DIR/env.sh"

mkdir -p "$ENV_DIR" 2>/dev/null || true

# Kein XDG_RUNTIME_DIR im Container – sonst startet dbus nicht.
unset XDG_RUNTIME_DIR

# Session-Bus (dauerhaft, --fork)
bus_out=$(dbus-daemon --session --fork --print-address=1 --print-pid=1 2>/dev/null)
bus_addr=$(printf '%s\n' "$bus_out" | sed -n '1p')
bus_pid=$(printf '%s\n' "$bus_out" | sed -n '2p')

if [[ -z "$bus_addr" ]]; then
  echo "Session-Bus konnte nicht gestartet werden." >&2
  exit 1
fi

export DBUS_SESSION_BUS_ADDRESS="$bus_addr"
export DBUS_SESSION_BUS_PID="$bus_pid"

# Keyring-Daemon starten (Login-Keyring ist passwortlos vorbereitet).
keyring_env=$(echo "" | gnome-keyring-daemon --start --replace --components=secrets 2>/dev/null)
if [[ -n "$keyring_env" ]]; then
  eval "$keyring_env" 2>/dev/null || true
fi

# Umgebung für alle anderen Prozesse bereitstellen
{
  printf "export DBUS_SESSION_BUS_ADDRESS='%s'\n" "$bus_addr"
  printf "export GNOME_KEYRING_CONTROL='%s'\n" "${GNOME_KEYRING_CONTROL:-}"
  printf "export SSH_AUTH_SOCK='%s'\n" "${SSH_AUTH_SOCK:-}"
} >"$ENV_FILE"
chmod 0644 "$ENV_FILE" 2>/dev/null || true

echo "Keyring-Session bereit: $bus_addr"

# Prozess am Leben halten, solange der Dienst läuft
exec sleep infinity