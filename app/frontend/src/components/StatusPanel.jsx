import { useState } from "react";
import { bytes, duration } from "../format.js";
import {
  HardDrive,
  Monitor,
  Network,
  Server,
  Shield,
  ShieldOff,
} from "./Icons.jsx";

function ServiceChip({ label, active }) {
  return (
    <span className={`chip ${active ? "chip-ok" : "chip-off"}`}>
      <span className="dot" />
      {label}
    </span>
  );
}

function CopyButton({ value }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(value);
      } else {
        const helper = document.createElement("textarea");
        helper.value = value;
        helper.style.position = "fixed";
        helper.style.opacity = "0";
        document.body.appendChild(helper);
        helper.select();
        document.execCommand("copy");
        helper.remove();
      }
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  }

  return (
    <button type="button" className="btn btn-ghost" onClick={copy}>
      {copied ? "Kopiert ✓" : "Kopieren"}
    </button>
  );
}

export default function StatusPanel({ status }) {
  if (!status) {
    return (
      <div className="card">
        <div className="card-head">
          <h2>Status</h2>
        </div>
        <p className="muted">Lade Systemstatus …</p>
      </div>
    );
  }

  const vpn = status.vpn || {};
  const disk = status.disk || {};
  const services = status.services || {};
  const usedPercent =
    disk.total > 0 ? Math.min(100, Math.round((disk.used / disk.total) * 100)) : 0;
  const smbPath = `\\\\${status.ip}\\${status.samba?.share ?? "downloads"}`;
  const rdpHost = status.rdp?.host ?? status.ip;
  const rdpUser = status.rdp?.user ?? "proton";
  const xfreerdpCmd = `xfreerdp /v:${rdpHost} /u:${rdpUser} /kbd:German /size:1920x1080 /f /clipboard`;
  const sambaMount = `sudo mount -t cifs -o username=${rdpUser},vers=3.0 //${rdpHost}/${status.samba?.share ?? "downloads"} /mnt/downloads`;

  return (
    <>
      <section className="card">
        <div className="card-head">
          <h2>Verbinden (RDP-Desktop)</h2>
        </div>
        <p className="muted small">
          Auf deinem Linux-PC ausführen – öffnet den Desktop in Vollbild mit
          deutschem Tastatur-Layout (Passwort: dein RDP-Passwort).
        </p>
        <div className="connect-row">
          <code className="mono connect-cmd">{xfreerdpCmd}</code>
          <CopyButton value={xfreerdpCmd} />
        </div>
        <p className="muted small">
          Windows/macOS: das fertige <strong>proton-download-box.rdp</strong>{" "}
          aus dem Tab „Dateien“ doppelklicken. Remmina: Verbindung bearbeiten →
          „Client-Auflösung“ + Vollbild.
        </p>
        <details className="connect-details">
          <summary>Samba unter Linux mounten</summary>
          <div className="connect-row">
            <code className="mono connect-cmd">{sambaMount}</code>
            <CopyButton value={sambaMount} />
          </div>
          <p className="muted small">
            Im Dateimanager geht auch <code>smb://{rdpHost}/downloads</code>{" "}
            (Benutzer {rdpUser}).
          </p>
        </details>
      </section>

      <section className="card">
        <div className="card-head">
          <h2>VPN-Tunnel</h2>
          <span className={`badge ${vpn.connected ? "badge-ok" : "badge-off"}`}>
            <span className="dot" />
            {vpn.connected ? "Verbunden" : "Getrennt"}
          </span>
        </div>

        <div className={`vpn-state ${vpn.connected ? "is-on" : "is-off"}`}>
          <div className="vpn-icon">
            {vpn.connected ? <Shield size={26} /> : <ShieldOff size={26} />}
          </div>
          <div className="vpn-text">
            <strong>
              {vpn.connected ? vpn.connection : "Kein Proton-Tunnel aktiv"}
            </strong>
            <span>
              {vpn.connected
                ? `${vpn.type || "VPN"} · ${vpn.interface || "–"}`
                : vpn.available
                  ? "NetworkManager bereit"
                  : vpn.detail || "NetworkManager nicht erreichbar"}
            </span>
          </div>
        </div>

        <dl className="kv">
          <div>
            <dt>Öffentliche IP</dt>
            <dd className="mono">{vpn.public_ip || "–"}</dd>
          </div>
          <div>
            <dt>Interface</dt>
            <dd className="mono">{vpn.interface || "–"}</dd>
          </div>
        </dl>

        {!vpn.connected && (
          <p className="hint">
            Per RDP anmelden, Proton VPN starten und verbinden. Killswitch ist
            standardmäßig aus (hält RDP/Web/Samba erreichbar); an/aus geht per{" "}
            <code>pdb-killswitch on</code> / <code>off</code>.
          </p>
        )}
      </section>

      <section className="card">
        <div className="card-head">
          <h2>System</h2>
          <span className="muted mono">{status.hostname}</span>
        </div>

        <dl className="kv">
          <div>
            <dt>Laufzeit</dt>
            <dd>{duration(status.uptime)}</dd>
          </div>
          <div>
            <dt>Version</dt>
            <dd className="mono">v{status.version}</dd>
          </div>
        </dl>

        <div className="disk">
          <div className="disk-head">
            <span>
              <HardDrive size={15} /> Speicher
            </span>
            <span className="mono">
              {bytes(disk.used)} / {bytes(disk.total)}
            </span>
          </div>
          <div className="bar">
            <span style={{ width: `${usedPercent}%` }} />
          </div>
          <p className="muted small">{bytes(disk.free)} frei</p>
        </div>

        <div className="chips">
          <ServiceChip label="Web UI" active={services.web} />
          <ServiceChip label="xrdp" active={services.xrdp} />
          <ServiceChip label="NetworkManager" active={services.networkmanager} />
          <ServiceChip label="Samba" active={services.smbd} />
        </div>
      </section>

      <section className="card">
        <div className="card-head">
          <h2>Zugriff</h2>
        </div>

        <ul className="access-list">
          <li>
            <span className="access-icon">
              <Network size={16} />
            </span>
            <div>
              <span className="access-label">Web UI</span>
              <code>
                http://{status.ip}:{status.port}
              </code>
            </div>
          </li>
          <li>
            <span className="access-icon">
              <Monitor size={16} />
            </span>
            <div>
              <span className="access-label">RDP-Desktop</span>
              <code>
                {status.rdp?.host}:{status.rdp?.port} · Benutzer {status.rdp?.user}
              </code>
            </div>
          </li>
          <li>
            <span className="access-icon">
              <Server size={16} />
            </span>
            <div>
              <span className="access-label">Samba-Freigabe</span>
              <code>{smbPath}</code>
            </div>
          </li>
        </ul>
      </section>
    </>
  );
}
