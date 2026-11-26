import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api.js";
import { bytes, relative } from "../format.js";
import {
  ChevronRight,
  Download,
  File,
  Folder,
  Pencil,
  Plus,
  Refresh,
  Trash,
  Upload,
  X,
} from "./Icons.jsx";

export default function FileManager({ focus, onUnauthorized }) {
  const [path, setPath] = useState("");
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [uploading, setUploading] = useState(0);
  const [creating, setCreating] = useState(false);
  const [newName, setNewName] = useState("");
  const fileInput = useRef(null);

  const load = useCallback(
    async (target) => {
      setLoading(true);
      try {
        const result = await api.files(target);
        setData(result);
        setError("");
      } catch (err) {
        if (err.status === 401) {
          onUnauthorized();
        } else if (err.status === 404 && target) {
          setPath("");
        } else {
          setError(err.message);
        }
      } finally {
        setLoading(false);
      }
    },
    [onUnauthorized],
  );

  useEffect(() => {
    load(path);
  }, [path, load]);

  useEffect(() => {
    if (focus && typeof focus.path === "string") setPath(focus.path);
  }, [focus]);

  async function handleUpload(event) {
    const files = Array.from(event.target.files || []);
    event.target.value = "";
    if (!files.length) return;

    setUploading(files.length);
    setError("");
    try {
      for (const file of files) {
        await api.upload(path, file);
      }
      await load(path);
    } catch (err) {
      if (err.status === 401) onUnauthorized();
      else setError(err.message);
    } finally {
      setUploading(0);
    }
  }

  async function createFolder(event) {
    event.preventDefault();
    const name = newName.trim();
    if (!name) return;
    try {
      await api.mkdir(path, name);
      setNewName("");
      setCreating(false);
      await load(path);
    } catch (err) {
      setError(err.message);
    }
  }

  async function remove(entry) {
    const question = entry.is_dir
      ? `Ordner "${entry.name}" mit gesamtem Inhalt löschen?`
      : `Datei "${entry.name}" löschen?`;
    if (!window.confirm(question)) return;
    try {
      await api.remove(entry.path, entry.is_dir);
      await load(path);
    } catch (err) {
      setError(err.message);
    }
  }

  async function rename(entry) {
    const name = window.prompt("Neuer Name", entry.name);
    if (!name || name === entry.name) return;
    try {
      await api.rename(entry.path, name);
      await load(path);
    } catch (err) {
      setError(err.message);
    }
  }

  const current = data?.path ?? path;
  const segments = current ? current.split("/") : [];
  const entries = data?.entries ?? [];
  const totalSize = entries.reduce(
    (sum, entry) => sum + (entry.is_dir ? 0 : entry.size),
    0,
  );

  return (
    <section className="card card-files">
      <div className="card-head">
        <h2>Dateien</h2>
        <div className="toolbar">
          <button
            className="btn btn-ghost btn-sm"
            onClick={() => fileInput.current?.click()}
            disabled={uploading > 0}
          >
            <Upload size={15} />
            {uploading > 0 ? `Hochladen (${uploading}) …` : "Hochladen"}
          </button>
          <button
            className="btn btn-ghost btn-sm"
            onClick={() => setCreating((value) => !value)}
          >
            <Plus size={15} /> Ordner
          </button>
          <button
            className="btn btn-ghost btn-sm"
            onClick={() => load(path)}
            title="Aktualisieren"
          >
            <Refresh size={15} />
          </button>
          <input
            ref={fileInput}
            type="file"
            multiple
            hidden
            onChange={handleUpload}
          />
        </div>
      </div>

      <nav className="breadcrumb" aria-label="Pfad">
        <button onClick={() => setPath("")}>Downloads</button>
        {segments.map((segment, index) => (
          <Fragment key={`${segment}-${index}`}>
            <ChevronRight size={13} />
            <button onClick={() => setPath(segments.slice(0, index + 1).join("/"))}>
              {segment}
            </button>
          </Fragment>
        ))}
      </nav>

      {creating && (
        <form className="new-folder" onSubmit={createFolder}>
          <div className="input-wrap grow">
            <Folder size={16} />
            <input
              value={newName}
              onChange={(event) => setNewName(event.target.value)}
              placeholder="Ordnername"
              autoFocus
            />
          </div>
          <button className="btn btn-primary btn-sm" type="submit">
            Anlegen
          </button>
          <button
            className="btn btn-ghost btn-sm"
            type="button"
            onClick={() => {
              setCreating(false);
              setNewName("");
            }}
          >
            <X size={15} />
          </button>
        </form>
      )}

      {error && <p className="form-error">{error}</p>}

      <div className={`file-table-wrap ${loading ? "is-loading" : ""}`}>
        {entries.length === 0 && !loading ? (
          <p className="empty">
            Dieser Ordner ist leer. Lade eine Datei hoch oder starte einen Download.
          </p>
        ) : (
          <table className="file-table">
            <thead>
              <tr>
                <th>Name</th>
                <th className="col-size">Größe</th>
                <th className="col-time">Geändert</th>
                <th className="col-actions" aria-label="Aktionen" />
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => (
                <tr key={entry.path}>
                  <td>
                    <button
                      className={`file-name ${entry.is_dir ? "is-dir" : ""}`}
                      onClick={() => entry.is_dir && setPath(entry.path)}
                      disabled={!entry.is_dir}
                    >
                      <span className="file-icon">
                        {entry.is_dir ? <Folder size={17} /> : <File size={17} />}
                      </span>
                      <span className="file-label">{entry.name}</span>
                    </button>
                  </td>
                  <td className="col-size mono muted">
                    {entry.is_dir ? "–" : bytes(entry.size)}
                  </td>
                  <td className="col-time muted">{relative(entry.mtime)}</td>
                  <td className="col-actions">
                    <div className="row-actions">
                      {!entry.is_dir && (
                        <a
                          className="icon-btn"
                          href={api.fileUrl(entry.path)}
                          title="Herunterladen"
                        >
                          <Download size={16} />
                        </a>
                      )}
                      <button
                        className="icon-btn"
                        onClick={() => rename(entry)}
                        title="Umbenennen"
                      >
                        <Pencil size={15} />
                      </button>
                      <button
                        className="icon-btn danger"
                        onClick={() => remove(entry)}
                        title="Löschen"
                      >
                        <Trash size={16} />
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <footer className="file-footer">
        <span className="muted small">
          {entries.length} Einträge · {bytes(totalSize)}
        </span>
        <span className="muted small mono">{data?.path || "/"}</span>
      </footer>
    </section>
  );
}
