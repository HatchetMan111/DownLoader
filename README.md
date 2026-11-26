# Proton Download Box – LXC-Installer für Proxmox VE

Eine lokale Download-Station als Proxmox-LXC im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE):
ein Einzeiler erstellt den Container, installiert alles und verifiziert
selbst, dass die Web-UI läuft.

**Zweck:** Dateien aus dem Internet auf eine Box hinter dem Proton-VPN-Tunnel
laden (Share-Hoster, große ISOs, eigene Uploads) und bequem vom eigenen PC
abholen. Die VPN-Verbindung samt **Killswitch** wird in der offiziellen
**Proton-VPN-App** (Free) bedient, die per **RDP-Desktop** erreichbar ist.
Die Web-UI zeigt den Tunnelstatus, verwaltet Downloads und Dateien.

| | |
|---|---|
| App-Name | `proton-download-box` |
| Tech-Stack | Debian 12 · XFCE · xrdp · Proton VPN App · Python/FastAPI · React/Vite |
| Web-UI-Port | `8080` |
| Standard-Ressourcen | 2 vCPU · 4 GB RAM · 24 GB Disk (anpassbar) |
| Repo | [`HatchetMan111/DownLoader`](https://github.com/HatchetMan111/DownLoader) |

> **Proton Free Limits:** kein P2P/Torrents, 1 Gerät gleichzeitig, begrenzte
> Serverauswahl. Manuelle WireGuard/OpenVPN-Configs gibt es bei Free nicht –
> deshalb läuft hier die offizielle App.

---

## Einzeiler-Installation (root auf dem Proxmox-Host)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DownLoader/main/install/proton-download-box.sh)"
```

Der Installer:

- wählt automatisch die **nächste freie CT-ID** (überschreibbar mit `--id`),
- lädt ein Debian-12-Template und legt einen **unprivilegierten LXC** an
  (`onboot=1`, `/dev/net/tun` durchgereicht),
- installiert XFCE + xrdp, die Proton-VPN-App, FastAPI, die gebaute React-UI
  und Samba,
- richtet die **systemd-Unit mit `Restart=always`** und
  `After=network-online.target` ein,
- richtet eine minimale **nftables-Firewall** ein (22, 8080, 3389, Samba offen),
- **verifiziert sich selbst**: Service aktiv, HTTP-Check auf `localhost:8080`,
  danach vom Host über die Container-IP – schlägt das fehl, wird die
  Container-Firewall automatisch entschärft und erneut getestet,
- gibt am Ende URL, IP und alle Zugangsdaten aus.

Bei Fehlern wird die **komplette Fehlerkette** ausgegeben (Exit-Code, Zeile,
Callstack, Container-Log, Journal-Auszug) – niemals nur die letzte Fehlerzeile.
Mit `--debug` gibt es zusätzlich ein vollständiges `bash -x`-Log unter
`/root/proton-download-box-debug-<ts>.log`.

## Optionen

| Flag | Default | Bedeutung |
|---|---|---|
| `--id <100-999>` | nächste freie | Container-ID |
| `--hostname <name>` | `proton-download-box` | Container-Hostname |
| `--cores` / `--ram` / `--swap` / `--disk` | 2 / 4096 / 1024 / 24 | Ressourcen |
| `--storage` / `--template-storage` | automatisch | Ziel-Storage |
| `--bridge` / `--ip` / `--gw` | `vmbr0` / `dhcp` / – | Netzwerk |
| `--port` | `8080` | Web-UI-Port |
| `--tz` | `Europe/Berlin` | Zeitzone |
| `--rdp-user` | `proton` | Desktop-Benutzer |
| `--web-password` / `--rdp-password` | generiert | Passwörter |
| `--local-dir <pfad>` | – | Lokalen Checkout statt GitHub installieren |
| `--check` | – | Nur bestehenden Container prüfen |
| `--uninstall` | – | Container löschen (braucht `--id`) |
| `--dry-run` / `--debug` / `-y` | – | Planen / `bash -x`-Log / keine Rückfragen |

Beispiele:

```bash
# feste ID und statische IP
... | bash -s -- --id 121 --ip 192.168.1.50/24 --gw 192.168.1.1

# kleiner, mit eigenem Passwort
... | bash -s -- --ram 2048 --disk 16 --web-password "MeinPasswort"
```

## Nach der Installation

1. **RDP** auf `<CT-IP>:3389` (Benutzer `proton`, Passwort aus der
   Installationsausgabe bzw. `/root/proton-download-box-credentials.txt`
   im Container).
2. **Proton VPN** starten, mit dem Free-Account anmelden, Server verbinden
   und in den **Einstellungen den Killswitch aktivieren**. Proton Free hat
   keinen Headless-Modus dafür – das läuft bewusst über die App-UI.
3. Downloads über die **Web UI** starten, Dateien per Browser **herunterladen**
   oder per **Samba** (`\\<CT-IP>\downloads`) abholen. Downloads laufen durch
   den Tunnel, sobald die VPN-App verbunden ist.

> **Proton Free Limits:** kein P2P/Torrents, 1 Gerät gleichzeitig, begrenzte
> Serverauswahl. Die Web-UI zeigt Tunnelstatus und öffentliche IP, damit man
> den Tunnel prüfen kann.

## Update

Einfach denselben Einzeiler erneut ausführen (oder mit `--id <CT-ID>`).
Der Installer erkennt die bestehende Installation, aktualisiert Code und Unit
und **behält alle Passwörter**.

## Deinstall

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DownLoader/main/install/proton-download-box.sh)" -- --uninstall --id 121
```

Manuell: `pct stop 121 && pct destroy 121 --purge` (löscht inkl. Daten – vorher
Downloads sichern!).

## Fehlerdiagnose

Der Installer gibt bei Fehlern die **komplette Fehlerkette** aus: Exit-Code,
Zeile, Callstack, Container-Log und Journal-Auszug – nicht nur die letzte
Zeile. Für ein vollständiges `bash -x`-Log:

```bash
bash install/proton-download-box.sh --debug   # oder: ... | bash -s -- --debug
```

Logdateien:
- Host: `/root/proton-download-box-debug-<ts>.log` (nur mit `--debug`)
- Container: `/var/log/proton-download-box-install.log`
- Service: `pct exec <ID> -- journalctl -u proton-download-box -f`

## Repository-Layout

```
install/proton-download-box.sh      # Proxmox-Installer (Einzeiler-Ziel)
scripts/install-inside.sh           # Installation im Container
config/proton-download-box.service  # systemd-Unit
app/backend/main.py                 # FastAPI-Backend
app/frontend/                       # React + Vite (Quellcode)
app/frontend/dist/                  # gebaute UI (vom Installer genutzt)
test/lint.sh                        # statische Prüfungen
test/smoke.sh                       # API-Smoke-Test ohne Proxmox (33 Checks)
test/installer.sh                   # Installer-Logik mit pct/pvesm-Stubs (20 Checks)
test/pve-reboot-test.sh             # Install → Reboot → UI erreichbar (auf dem Host)
docs/TROUBLESHOOTING.md             # Fehlerdiagnose
```

## Lokale Tests

```bash
# statische Prüfungen (ShellCheck, bash -n, py_compile, Payload-Inhalt)
bash test/lint.sh

# API-Smoke-Test ohne Proxmox (Backend + UI + Downloader + Sicherheit)
bash test/smoke.sh

# Installer-Logik mit pct/pvesm-Stubs (ohne echten Proxmox-Host)
bash test/installer.sh

# Auf dem Proxmox-Host: Install → Reboot → Web UI wieder erreichbar
bash test/pve-reboot-test.sh --id 121
```

## Testablauf auf dem Proxmox-Host (Installation → Reboot → Web UI)

```bash
git clone https://github.com/HatchetMan111/DownLoader.git && cd DownLoader
bash install/proton-download-box.sh --id 121       # Installation
bash test/pve-reboot-test.sh --id 121 --port 8080  # Install → Reboot → UI erreichbar
```

Erwartete Ausgabe (Auszug):

```
==> [1/4] Service + Web UI vor dem Reboot
  ok  Service enabled (Autostart)
  ok  Service aktiv, IP 192.168.1.50
{"status":"ok","app":"proton-download-box","version":"1.0.0"}
==> [2/4] Container rebooten
==> [3/4] Service + Web UI nach dem Reboot
  ok  Service nach Reboot aktiv (systemd Autostart)
{"status":"ok","app":"proton-download-box","version":"1.0.0"}
==> [4/4] Log-Auszug
● proton-download-box.service - Proton Download Box (FastAPI + React web UI)
     Loaded: loaded (/etc/systemd/system/proton-download-box.service; enabled)
     Active: active (running) ...
ERGEBNIS: Installation → Reboot → Web UI erreichbar: OK
```

> **Hinweis zur Verifikation:** Backend, API, Frontend-Build und
> Installer-Logik sind hier vollständig getestet (33 API-Checks,
> 24 Installer-Checks – alle grün). Den LXC-End-to-End-Lauf auf einem echten
> Proxmox-Host (inkl. Reboot) liefert `test/pve-reboot-test.sh` – dafür wird
> ein Proxmox-Host benötigt.

## Hinweise / Limits

- **Proton Free** unterstützt kein P2P/Torrents, nur ein Gerät gleichzeitig
  und eine begrenzte Serverauswahl. Manuelle WireGuard/OpenVPN-Konfigs gibt es
  bei Free **nicht** – deshalb läuft hier die offizielle App.
- Der **Killswitch** wird über die Proton-App-UI (im RDP-Desktop) gesetzt,
  nicht über das Skript – genau wie gewünscht. Die Web-UI zeigt den Status
  read-only an (via NetworkManager).
- Der Container ist **unprivilegiert**. Sollte in eurem Setup Proton VPN im
  LXC nicht funktionieren (TUN/WireGuard/Polkit), kann die gleiche Box auch
  als VM installiert werden – dieses Skript dient dann als Ausgangspunkt.
