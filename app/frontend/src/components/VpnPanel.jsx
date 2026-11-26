import { useCallback, useEffect, useState } from "react";
import { api } from "../api.js";
import { Check, Network, Refresh, Shield, X, Alert } from "./Icons.jsx";

const ICON = {
  pass: <Check size={14} />,
  warn: <Alert size={14} />,
  fail: <X size={14} />,
};

export default function VpnPanel({ onUnauthorized, onChanged }) {
  const [data, setData] = useState(null);
  const [country, setCountry] = useState("");
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [leak, setLeak] = useState(null);

  const load = useCallback(async () => {
    try {
      const result = await api.vpnOptions();
      setData(result);
      setError("");
    } catch (err) {
      if (err.status === 401) onUnauthorized();
      else setError(err.message);
    }
  }, [onUnauthorized]);

  useEffect(() => {
    load();
  }, [load]);

  async function run(action, fn) {
    setBusy(action);
    setError("");
    try {
      await fn();
      await load();
      if (onChanged) onChanged();
    } catch (err) {
      setError(err.status === 401 ? "Sitzung abgelaufen." : err.message);
    } finally {
      setBusy("");
    }
  }

  async function leakTest() {
    setBusy("leak");
    setError("");
    try {
      setLeak(await api.vpnLeaktest());
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy("");
    }
  }

  const connected = data?.status?.connected;
  const killswitch = data?.killswitch;

  return (
    <section className="card">
      <div className="card-head">
        <h2>VPN-Steuerung</h2>
        <button className="btn btn-ghost btn-sm" onClick={load} title="Aktualisieren">
          <Refresh size={14} />
        </button>
      </div>

      <div className="vpn-controls">
        <div className="input-wrap grow">
          <Network size={16} />
          <select
            value={country}
            onChange={(event) => setCountry(event.target.value)}
            aria-label="Serverstandort"
          >
            <option value="">Automatisch (schnellster Server)</option>
            {(data?.countries || []).map((item) => (
              <option key={item.code} value={item.code}>
                {item.name} ({item.code})
              </option>
            ))}
          </select>
        </div>

        <button
          className="btn btn-primary"
          disabled={busy !== ""}
          onClick={() => run("connect", () => api.vpnConnect(country))}
        >
          <Shield size={15} />
          {busy === "connect" ? "Verbinde …" : "Verbinden"}
        </button>
        <button
          className="btn btn-ghost"
          disabled={busy !== ""}
          onClick={() => run("disconnect", () => api.vpnDisconnect())}
        >
          {busy === "disconnect" ? "Trenne …" : "Trennen"}
        </button>
      </div>

      {data?.status?.server && (
        <p className="muted small">
          Aktuell: <span className="mono">{data.status.server}</span>
          {data.status.location ? ` · ${data.status.location}` : ""}
        </p>
      )}

      <div className="vpn-row">
        <span className="vpn-row-label">
          Killswitch <span className="muted small">(blockt alles ohne Tunnel)</span>
        </span>
        <button
          className={`btn btn-sm ${killswitch ? "btn-primary" : "btn-ghost"}`}
          disabled={busy !== "" || killswitch === null}
          onClick={() =>
            run("killswitch", () => api.vpnKillswitch(!killswitch))
          }
        >
          {killswitch === null ? "unbekannt" : killswitch ? "Aktiv" : "Aus"}
        </button>
      </div>

      <div className="vpn-row">
        <span className="vpn-row-label">
          Anonymität prüfen
          <span className="muted small">IP · DNS · IPv6 · Killswitch</span>
        </span>
        <button
          className="btn btn-ghost btn-sm"
          disabled={busy !== ""}
          onClick={leakTest}
        >
          {busy === "leak" ? "Prüfe …" : "Leak-Test"}
        </button>
      </div>

      {error && <p className="form-error">{error}</p>}

      {leak && (
        <div className="leak">
          <p
            className={`leak-summary ${
              leak.checks.some((c) => c.status === "fail") ? "is-bad" : "is-ok"
            }`}
          >
            {leak.summary}
          </p>
          <ul className="leak-list">
            {leak.checks.map((check) => (
              <li key={check.id} className={`leak-item is-${check.status}`}>
                <span className="leak-icon">{ICON[check.status]}</span>
                <div>
                  <strong>{check.label}</strong>
                  <span className="muted small mono">{check.detail}</span>
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}

      {!connected && data && (
        <p className="hint">
          Noch nicht verbunden. Beim ersten Mal einmalig im Container anmelden:
          <code>pct exec &lt;CT-ID&gt; -- bash /usr/local/bin/pdb-proton-setup</code>
        </p>
      )}
    </section>
  );
}