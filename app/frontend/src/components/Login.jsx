import { useState } from "react";
import { api } from "../api.js";
import { Lock, Shield } from "./Icons.jsx";

export default function Login({ onSuccess }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      await api.login(password);
      onSuccess();
    } catch (err) {
      setError(err.status === 401 ? "Falsches Passwort." : err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login-screen">
      <form className="login-card" onSubmit={submit}>
        <div className="login-mark">
          <Shield size={30} />
        </div>
        <h1>Proton Download Box</h1>
        <p className="login-sub">
          Lokale Download-Station hinter dem Proton-VPN-Tunnel.
        </p>

        <label className="field">
          <span>Passwort</span>
          <div className="input-wrap">
            <Lock size={16} />
            <input
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              placeholder="Passwort aus der Installation"
              autoFocus
              autoComplete="current-password"
              required
            />
          </div>
        </label>

        {error && <p className="form-error">{error}</p>}

        <button className="btn btn-primary btn-block" type="submit" disabled={busy}>
          {busy ? "Anmelden …" : "Anmelden"}
        </button>

        <p className="login-hint">
          Das Passwort wurde bei der Installation ausgegeben und liegt im Container
          unter <code>/root/proton-download-box-credentials.txt</code>.
        </p>
      </form>
    </div>
  );
}
