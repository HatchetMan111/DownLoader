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

  return (
    <>
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
            Per RDP anmelden, Proton VPN starten und verbinden. Den Killswitch in
            den Einstellungen der Proton-App aktivieren.
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
