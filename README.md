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
| `--proton-email <mail>` | – | Proton-Account: automatischer VPN-Login direkt beim Install |
| `--proton-password <pw>` | – | Proton-Passwort (nur mit `--proton-email`) |
| `--proton-totp` | – | Login mit Authenticator-App (2FA statt Security-Key) |
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

# mit automatischem Proton-Login direkt beim Install
... | bash -s -- --proton-email "du@proton.me" --proton-password "deinpw"
# (mit Authenticator-App/2FA zusätzlich: --proton-totp)
```

> **Tipp:** Gibst du `--proton-email` + `--proton-password` an, erledigt der
> Installer den Proton-Login + Verbindungsaufbau **gleich mit** – du musst
> danach nichts mehr per RDP/Terminal machen. Ohne diese Flags läuft der Login
> später einmalig über `pct enter <ID>` → `bash /usr/local/bin/pdb-proton-setup`.

## Nach der Installation: VPN einrichten (einmalig, ~2 Minuten)

Der Proton-Login ist der einzige Schritt, der einmalig über den Desktop
laufen muss — Proton speichert die Sitzung verschlüsselt im Benutzer-Keyring,
und beim Login können 2FA/Captcha auftreten, die kein Skript ausfüllen kann.
Danach brauchst du RDP nur noch, wenn du etwas in der App ändern willst.

**Proton VPN öffnet sich ab Installer-Version 2026-11-26.7 automatisch
direkt nach der RDP-Anmeldung** (XFCE-Autostart). Es liegt zusätzlich ein
Icon auf dem Desktop.

### 1. Per RDP mit dem Desktop verbinden

RDP ist ein eigenes Protokoll — der Browser funktioniert dafür **nicht**
(`ERR_INVALID_HTTP_RESPONSE` ist normal, wenn man Port 3389 im Browser
öffnet). Nimm stattdessen den RDP-Client deines Systems:

| System | Client | So geht's |
|---|---|---|
| **Windows** | „Remotedesktopverbindung" (vorinstalliert) | `Windows + R` → `mstsc` → Rechner `<CT-IP>` → Verbinden |
| **macOS** | „Windows App" (ehem. MS Remote Desktop, App Store) | PC hinzufügen → `<CT-IP>` |
| **Ubuntu/Zorin** | „Remmina" (vorinstalliert) | Remmina öffnen → `+` → Protokoll RDP, Server `<CT-IP>` |
| **Linux (Terminal)** | `xfreerdp` | `xfreerdp /v:<CT-IP> /u:proton /dynamic-size` |

Anmeldung am Desktop: Benutzer `proton`, Passwort aus der
Installationsausgabe (liegt auch im Container unter
`/root/proton-download-box-credentials.txt`).

### Desktop passt nicht auf den Bildschirm / ist zu klein? → Fertiges Profil importieren

Der Installer legt **fertig konfigurierte RDP-Client-Profile** auf die Box
(mit erzwungener, großer Auflösung – kein 800×600 mehr). Du musst nichts
einstellen:

**Windows (häufigster Fall):**
1. `\\<CT-IP>\downloads\proton-download-box.rdp` öffnen (oder Web UI →
   **Dateien** → `proton-download-box.rdp` herunterladen)
2. Doppelklick → „Remotedesktopverbindung" startet im **Vollbild** mit
   deiner Monitor-Auflösung → Benutzer `proton` + RDP-Passwort → fertig

**Linux (Remmina):**
1. Web UI → **Dateien** → `proton-download-box.remmina` herunterladen
2. Remmina: **Menü ☰ → Werkzeuge → Importieren** → Datei wählen →
   Doppelklick → Passwort → fertig

**macOS („Windows App"):** PC hinzufügen → `<CT-IP>` → vor dem Verbinden
unter „Anzeige" die Auflösung auf **„Monitor"** (Vollbild) stellen.

**Empfohlen (xfreerdp, Linux-Terminal) – Vollbild + deutsches Layout:**
```bash
xfreerdp /v:<CT-IP> /u:proton /kbd:German /size:1920x1080 /f /clipboard
```
`/f` = Vollbild (1920×1080), `/kbd:German` = deutsche Tastatur (`@` = AltGr+Q).
Das ist der verlässlichste Weg – Remmina übernimmt die Auflösung beim Import
leider nicht immer sauber.

> Die Profile erzwingen Vollbild bzw. Client-Auflösung. Erzwingt dein Client
> trotzdem eine kleine Größe, maximiere das Fenster **bevor** du verbindest.
> Schriften sind auf der Box auf **11 pt / DPI 96** gesetzt, damit die
> Oberfläche auch in einem kleinen Fenster lesbar bleibt.

> **„Verbindung wird wiederhergestellt"?** Ab Installer-Version
> `2026-11-26.9` ist das xfwm4-Compositing deaktiviert — der häufigste
> Grund für abbrechende Sitzungen unter xrdp. Zusätzlich startet die
> Proton-App erst 3 Sekunden nach dem Desktop, damit der Session-Start
> nicht ins Stocken gerät.

> **RDP bricht ab, sobald der Tunnel steht?** Dann routet der LAN-Fix den
> Rückweg noch nicht. Auf dem Host nachziehen (PB-Subnetze + lokales Netz
> werden über eth0 geführt, inkl. Cross-Subnet-Clients wie 192.168.x):
> ```bash
> pct exec <ID> -- bash /usr/local/bin/pdb-lan-fix
> ```
> Läuft ab v25 automatisch bei jedem Tunnel-Aufbau (Dispatcher).

### 2. Proton VPN einrichten (direkt nach dem Login offen)

1. **Proton VPN** öffnet sich nach der Anmeldung automatisch
   (oder Desktop-Icon doppelklicken / im Terminal `protonvpn-app`).
2. **Sign in** → mit dem kostenlosen Proton-Account anmelden
   (evtl. 2FA-Code eingeben).
3. **Connect** → der schnellste Free-Server verbindet sich.
4. **Killswitch ist standardmäßig AUS** (hält RDP/Web/Samba erreichbar –
   bei aktivem Tunnel blockt er sonst den LAN-Zugriff). Wer ihn trotzdem will:
   `pct exec <ID> -- bash /usr/local/bin/pdb-killswitch on` (Achtung: danach
   LAN nur noch per `pct exec`; mit `off` wieder aus). Die Sitzung bleibt
   gespeichert, auch über Neustarts.

> **„Unlock login keyring" / „Authentication required"?** Der Installer legt
> den Login-Keyring **passwortlos** an (ab `2026-11-27.20`): ein leerer Keyring
> wird vom gnome-keyring-daemon **immer sofort und ohne Rückfrage** entsperrt –
> es gibt kein Passwort, das abgefragt werden könnte. Ein Autostart-Eintrag
> entsperrt ihn zusätzlich beim Login. **Kein PAM-Hook** mehr (der frühere
> `pam_gnome_keyring`-Ansatz mit RDP-Passwort scheiterte nach mehreren Re-Runs
> an einem Alt-Keyring → Dialog + „Passwort falsch"). Falls doch je ein Dialog
> erscheint: **einfach ENTER** drücken (leeres Passwort). Hinweis: die
> Proton-Sitzung liegt damit unverschlüsselt im Container – akzeptabel für eine
> isolierte Download-Box.

### Tastatur im RDP-Desktop

Der Desktop startet mit **deutschem Layout** (`de`) — `@` ist wie gewohnt
`AltGr+Q`, `z` und `y` sitzen richtig. Das Layout wird ab Version
`2026-11-27.11` an **drei** Stellen erzwungen (systemweit, direkt in
`startwm.sh` nach dem X-Start, und im Autostart mit Nachzügler), weil
xrdp/xorgxrdp beim Verbinden sonst das Layout des Clients übernimmt und auf
US zurückfällt. Anderes Layout? Installer mit `--kbd <layout>` ausführen
(z. B. `--kbd us`).

```bash
... | bash -s -- --id 109 --kbd us
```

### 3. Danach: Box im Alltag nutzen

- **Web UI** `http://<CT-IP>:8080` → Login mit dem Web-Passwort →
  VPN-Status oben, URL-Downloads starten, Dateien verwalten und auf den
  eigenen PC laden
- **Samba** `\\<CT-IP>\downloads` (Benutzer `proton`) → Dateien direkt
  im Explorer/Finder
- **RDP** nur noch bei Bedarf (z. B. Serverland wechseln)

### 4. VPN direkt aus der Web UI steuern

Der Tab **„VPN-Steuerung"** bietet alles, wofür man sonst den Desktop braucht:

| Funktion | Was passiert |
|---|---|
| **Serverstandort** | Dropdown mit NL/US/JP/RO/PL oder „Automatisch" → `protonvpn connect --country XX` |
| **Verbinden / Trennen** | startet/stoppt den Tunnel sofort |
| **Killswitch** | schaltet `standard` (an) bzw. `off` |
| **Leak-Test** | prüft Tunnel, öffentliche IP (Vergleich mit der IP von vor der Verbindung), DNS-Server, Namensauflösung, IPv6-Leck, Killswitch und LAN-Route — mit Klartext-Ergebnis pro Punkt |

Beispiel-Ergebnis des Leak-Tests:

```
Alles in Ordnung – Verbindung läuft über Proton VPN.
✓ VPN-Tunnel aktiv            proton0
✓ Öffentliche IP verschleiert 185.159.x.x (vorher 10.120.1.142)
✓ DNS über Proton             10.2.0.1, 10.2.0.2
✓ Namensauflösung funktioniert
✓ Kein IPv6-Leck             keine globale IPv6-Adresse
✓ Killswitch aktiv           standard
✓ LAN-Route (RDP/Samba erreichbar)
```

> Der Leak-Test ist eine **Plausibilitätsprüfung** (eigene Messungen im
> Container), kein externer Audit-Dienst. Er erkennt die typischen Fehler:
> Tunnel aus, echte IP sichtbar, ISP-DNS aktiv, IPv6 neben dem Tunnel.

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
test/smoke.sh                       # API-Smoke-Test ohne Proxmox (41 Checks)
test/installer.sh                   # Installer-Logik mit pct/pvesm-Stubs (23 Checks)
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
> Installer-Logik sind hier vollständig getestet (41 API-Checks,
> 23 Installer-Checks – alle grün). Den LXC-End-to-End-Lauf auf einem echten
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
