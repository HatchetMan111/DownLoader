#!/usr/bin/env bash
# =============================================================================
#  pdb-fix-nm-auth – NetworkManager-Autorisierung für den Container freischalten
#
#  Proton VPN legt seinen Tunnel über NetworkManager an. Fehlt die
#  Polkit-Freigabe, bricht der Aufbau nach wenigen Sekunden ab
#  ("Connecting" -> "Disconnected").
#
#  Dieses Skript schaltet die NM-eigene Polkit-Prüfung ab
#  (auth-polkit=false) und legt zusätzlich eine Polkit-Regel an.
#  Beides ist nur in einem isolierten Container vertretbar.
#
#  Aufruf (root): pct exec <CT-ID> -- bash /usr/local/bin/pdb-fix-nm-auth
# =============================================================================
set -u

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen (pct exec)."
  exit 1
fi

# 1) NM ohne Polkit autorisieren
cat >/etc/NetworkManager/conf.d/50-pdb-auth.conf <<'EOF'
[main]
auth-polkit=false
EOF

# 2) Polkit-Regel als zweite Absicherung
install -d -m 0755 /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/50-proton-download-box.rules <<'EOF'
// Container-isoliert: NetworkManager darf ohne Rückfrage bedient werden.
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0) {
        return polkit.Result.YES;
    }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/50-proton-download-box.rules

# 3) Dienste neu laden
systemctl reload dbus >/dev/null 2>&1 || true
systemctl restart polkit >/dev/null 2>&1 || true
systemctl restart NetworkManager >/dev/null 2>&1 || true
sleep 3

# 4) Prüfen
ok=true
grep -q '^auth-polkit=false' /etc/NetworkManager/conf.d/50-pdb-auth.conf || ok=false
[[ -f /etc/polkit-1/rules.d/50-proton-download-box.rules ]] || ok=false
systemctl is-active --quiet NetworkManager || ok=false

if [[ "$ok" == true ]]; then
  echo "NetworkManager-Autorisierung freigeschaltet (auth-polkit=false + Polkit-Regel)."
  nmcli -t -f NAME,TYPE,DEVICE connection show | sed 's/^/  /'
else
  echo "Freischaltung unvollständig – bitte obige Punkte prüfen."
  exit 1
fi