import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "./api.js";
import Downloader from "./components/Downloader.jsx";
import FileManager from "./components/FileManager.jsx";
import Login from "./components/Login.jsx";
import StatusPanel from "./components/StatusPanel.jsx";
import VpnPanel from "./components/VpnPanel.jsx";
import { Logout, Shield } from "./components/Icons.jsx";

export default function App() {
  const [auth, setAuth] = useState(null);
  const [status, setStatus] = useState(null);
  const [statusError, setStatusError] = useState("");
  const [focus, setFocus] = useState(null);
  const refreshStatusRef = useRef(null);

  const handleUnauthorized = useCallback(() => {
    setAuth(false);
    setStatus(null);
  }, []);

  useEffect(() => {
    let alive = true;
    api
      .session()
      .then(() => alive && setAuth(true))
      .catch(() => alive && setAuth(false));
    return () => {
      alive = false;
    };
  }, []);

  useEffect(() => {
    if (auth !== true) return undefined;

    let alive = true;
    const tick = async () => {
      try {
        const data = await api.status();
        if (alive) {
          setStatus(data);
          setStatusError("");
        }
      } catch (err) {
        if (!alive) return;
        if (err.status === 401) {
          setAuth(false);
        } else {
          setStatusError(err.message);
        }
      }
    };

    tick();
    const timer = setInterval(tick, 3000);
    refreshStatusRef.current = tick;
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [auth]);

  const refreshStatus = useCallback(() => {
    if (refreshStatusRef.current) refreshStatusRef.current();
  }, []);

  async function logout() {
    try {
      await api.logout();
    } catch {
      /* cookie is cleared server-side; ignore network hiccups */
    }
    setAuth(false);
    setStatus(null);
  }

  if (auth === null) {
    return (
      <div className="boot">
        <div className="spinner" />
        <p className="muted">Verbinde mit der Download-Box …</p>
      </div>
    );
  }

  if (auth === false) {
    return <Login onSuccess={() => setAuth(true)} />;
  }

  const vpn = status?.vpn;

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark">
            <Shield size={21} />
          </span>
          <div>
            <h1>Proton Download Box</h1>
            <p>
              {status
                ? `${status.hostname} · ${status.ip}`
                : "Lokale Download-Station"}
            </p>
          </div>
        </div>

        <div className="topbar-right">
          {vpn && (
            <span className={`pill ${vpn.connected ? "pill-ok" : "pill-off"}`}>
              <span className="dot" />
              {vpn.connected ? "VPN aktiv" : "VPN getrennt"}
            </span>
          )}
          <button className="btn btn-ghost btn-sm" onClick={logout}>
            <Logout size={15} /> Abmelden
          </button>
        </div>
      </header>

      <main className="layout">
        <aside className="sidebar">
          <StatusPanel status={status} />
        </aside>

        <div className="main-col">
          {statusError && <p className="banner">{statusError}</p>}
          <VpnPanel
            onUnauthorized={handleUnauthorized}
            onChanged={refreshStatus}
          />
          <Downloader
            onUnauthorized={handleUnauthorized}
            onReveal={(target) => setFocus({ path: target, nonce: Date.now() })}
          />
          <FileManager focus={focus} onUnauthorized={handleUnauthorized} />
        </div>
      </main>

      <p className="footnote">
        Downloads laufen im Container – bei aktivem Tunnel also durch Proton VPN.
        Proton Free erlaubt keine P2P-Torrents, ein Gerät und eine begrenzte
        Serverauswahl.
      </p>
    </div>
  );
}
