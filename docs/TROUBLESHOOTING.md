# Troubleshooting – proton-download-box

Alle Logs an einem Ort:

| Was | Wo |
|---|---|
| Installer (Host) | `/root/proton-download-box-debug-<ts>.log` (nur mit `--debug`) |
| Installer (Container) | `/var/log/proton-download-box-install.log` |
| Web-App | `pct exec <ID> -- journalctl -u proton-download-box -f` |
| xrdp | `pct exec <ID> -- journalctl -u xrdp -f` |
| Samba | `pct exec <ID> -- journalctl -u smbd -f` |

## Installer bricht ab

Der Installer gibt bei Fehlern die komplette Fehlerkette aus (Exit-Code, Zeile,
Callstack, Container-Log, Journal). Für einen vollständigen Trace:

```bash
bash install/proton-download-box.sh --debug --id 121
# Log liegt danach unter /root/proton-download-box-debug-<ts>.log
```

Container neu starten und Installer erneut ausführen (idempotent):

```bash
pct start 121 2>/dev/null; pct stop 121; bash install/proton-download-box.sh --id 121
```

## Web UI nicht erreichbar

```bash
pct exec 121 -- systemctl status proton-download-box -l
pct exec 121 -- journalctl -u proton-download-box -n 50
pct exec 121 -- curl -s http://127.0.0.1:8080/api/health     # lokal testen
curl -s http://$(pct exec 121 -- hostname -I | awk '{print $1}'):8080/api/health
```

- Lokal `ok`, vom Host aus nicht? → Firewall im Container:
  `pct exec 121 -- nft flush ruleset`
- Port falsch? → `pct exec 121 -- cat /etc/proton-download-box.env | grep PDB_PORT`

## Proton VPN verbindet nicht

1. Proton App muss im **RDP-Desktop** laufen (Benutzer `proton`).
2. Tunnel-Interface prüfen: `pct exec 121 -- nmcli con show --active`
3. Killswitch in der Proton-App testen (Einstellungen → Killswitch), dann
   Verbindungsstatus: `pct exec 121 -- nmcli con show --active`
4. Bei DNS-Problemen nach Killswitch-Aktivierung:
   `pct exec 121 -- cat /etc/resolv.conf` – sollte `10.2.0.1` zeigen, solange
   der Tunnel steht; beim Trennen wird die ursprüngliche Datei wiederhergestellt.

## Killswitch wirkt nicht

- Wird **nur** in der Proton-App-UI gesetzt (Einstellungen → Killswitch), nicht
  über das Skript oder die Web-UI. Proton Free hat keinen Headless-Modus dafür.
- Nach RDP-Anmeldung in der App aktivieren – die Web-UI zeigt dann den Status.

## Samba-Freigabe nicht erreichbar

```bash
pct exec 121 -- systemctl status smbd nmbd
pct exec 121 -- smbpasswd -e proton       # Benutzer reaktivieren
pct exec 121 -- cat /etc/samba/smb-proton-download-box.conf
```
Windows: `\\<CT-IP>\downloads` · macOS: `smb://<CT-IP>/downloads`

## Container startet nicht mehr

```bash
pct start 121
pct exec 121 -- journalctl -b -n 100
pct config 121          # onboot=1 und lxc.mount.entry für /dev/net/tun prüfen
```
