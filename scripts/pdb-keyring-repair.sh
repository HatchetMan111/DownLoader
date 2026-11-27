#!/usr/bin/env bash
# =============================================================================
#  pdb-keyring-repair – Keyring-Sammlung neu anlegen, entsperren, prüfen
#
#  Proton VPN speichert die VPN-Zugangsdaten im SecretService. Ist die
#  Sammlung gesperrt, bricht der Verbindungsaufbau nach wenigen Sekunden ab
#  ("KeyringLocked: Failed to unlock the collection!").
#
#  Aufruf (root): pct exec <CT-ID> -- bash /usr/local/bin/pdb-keyring-repair
# =============================================================================
set -u

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen (pct exec)."
  exit 1
fi

echo "=== 1. Dienste stoppen ==="
systemctl stop pdb-keyring 2>/dev/null || true
pkill -f gnome-keyring-daemon >/dev/null 2>&1 || true
sleep 1

echo "=== 2. Alte Sammlung entfernen ==="
rm -rf /home/proton/.local/share/keyrings
install -d -o proton -g proton -m 0700 /home/proton/.local/share/keyrings

echo "=== 3. Keyring-Dienst starten ==="
systemctl start pdb-keyring
sleep 4
systemctl status pdb-keyring --no-pager -l 2>&1 | tail -n 6

echo
echo "=== 4. Funktion prüfen (als proton) ==="
runuser -u proton -- env HOME=/home/proton bash -c '
  unset XDG_RUNTIME_DIR
  if [ -r /run/pdb-keyring/env.sh ]; then . /run/pdb-keyring/env.sh; fi
  printf probe | secret-tool store --label=pdb-probe pdb probe >/dev/null 2>&1 \
    && echo "  STORE  OK" || echo "  STORE  FEHLGESCHLAGEN"
  val=$(secret-tool lookup pdb probe 2>/dev/null)
  if [ "$val" = "probe" ]; then echo "  LOOKUP OK"; else echo "  LOOKUP FEHLGESCHLAGEN"; fi
'

echo
echo "Wenn STORE und LOOKUP beide OK sind, ist der Keyring bereit:"
echo "  pct exec <CT-ID> -- bash /usr/local/bin/pdb-proton-setup"