import { useCallback, useEffect, useState } from "react";
import { api } from "../api.js";
import { bytes, dirname, speed } from "../format.js";
import { Download, Folder, Trash, X } from "./Icons.jsx";

const STATUS_LABEL = {
  queued: "Wartet",
  running: "Lädt",
  done: "Fertig",
  error: "Fehler",
  canceled: "Abgebrochen",
};

function JobRow({ job, onCancel, onRemove, onReveal }) {
  const percent =
    job.total > 0 ? Math.min(100, (job.downloaded / job.total) * 100) : null;
  const active = job.status === "queued" || job.status === "running";

  return (
    <li className={`job job-${job.status}`}>
      <div className="job-top">
        <div className="job-name" title={job.filename || job.url}>
          {job.filename || job.url}
        </div>
        <span className={`badge badge-${job.status}`}>
          {STATUS_LABEL[job.status] || job.status}
        </span>
      </div>

      <div className={`bar ${percent === null && active ? "bar-indeterminate" : ""}`}>
        <span style={percent !== null ? { width: `${percent}%` } : undefined} />
      </div>

      <div className="job-meta">
        <span className="mono">
          {bytes(job.downloaded)}
          {job.total > 0 ? ` / ${bytes(job.total)}` : ""}
        </span>
        {job.status === "running" && job.speed > 0 && (
          <span className="mono muted">{speed(job.speed)}</span>
        )}
        {job.status === "done" && job.total > 0 && (
          <span className="mono muted">{bytes(job.total)}</span>
        )}
      </div>

      {job.status === "error" && job.error && (
        <p className="job-error">{job.error}</p>
      )}

      <div className="job-actions">
        {active && (
          <button className="btn btn-ghost btn-sm" onClick={() => onCancel(job.id)}>
            <X size={14} /> Abbrechen
          </button>
        )}
        {job.status === "done" && job.path && (
          <button
            className="btn btn-ghost btn-sm"
            onClick={() => onReveal(dirname(job.path))}
          >
            <Folder size={14} /> Anzeigen
          </button>
        )}
        {!active && (
          <button
            className="btn btn-ghost btn-sm danger"
            onClick={() => onRemove(job.id)}
          >
            <Trash size={14} /> Entfernen
          </button>
        )}
      </div>
    </li>
  );
}

export default function Downloader({ onUnauthorized, onReveal }) {
  const [url, setUrl] = useState("");
  const [filename, setFilename] = useState("");
  const [jobs, setJobs] = useState([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const data = await api.jobs();
      setJobs(data.jobs || []);
    } catch (err) {
      if (err.status === 401) onUnauthorized();
    }
  }, [onUnauthorized]);

  useEffect(() => {
    load();
    const timer = setInterval(load, 2000);
    return () => clearInterval(timer);
  }, [load]);

  async function submit(event) {
    event.preventDefault();
    if (!url.trim()) return;
    setBusy(true);
    setError("");
    try {
      await api.startJob(url.trim(), filename.trim());
      setUrl("");
      setFilename("");
      await load();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  async function cancel(id) {
    try {
      await api.cancelJob(id);
      await load();
    } catch (err) {
      setError(err.message);
    }
  }

  async function remove(id) {
    try {
      await api.removeJob(id);
      await load();
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <section className="card">
      <div className="card-head">
        <h2>Download</h2>
        <span className="muted small">HTTP/HTTPS · läuft im Container</span>
      </div>

      <form className="download-form" onSubmit={submit}>
        <div className="input-wrap grow">
          <Download size={16} />
          <input
            type="url"
            value={url}
            onChange={(event) => setUrl(event.target.value)}
            placeholder="https://example.com/datei.iso"
            required
            spellCheck="false"
          />
        </div>
        <div className="input-wrap filename">
          <input
            type="text"
            value={filename}
            onChange={(event) => setFilename(event.target.value)}
            placeholder="Dateiname (optional)"
            spellCheck="false"
          />
        </div>
        <button className="btn btn-primary" type="submit" disabled={busy}>
          {busy ? "Startet …" : "Starten"}
        </button>
      </form>

      {error && <p className="form-error">{error}</p>}

      {jobs.length === 0 ? (
        <p className="empty small">
          Noch keine Downloads. URL einfügen und starten – die Datei landet in
          <code>/srv/downloads</code>.
        </p>
      ) : (
        <ul className="jobs">
          {jobs.map((job) => (
            <JobRow
              key={job.id}
              job={job}
              onCancel={cancel}
              onRemove={remove}
              onReveal={onReveal}
            />
          ))}
        </ul>
      )}
    </section>
  );
}
