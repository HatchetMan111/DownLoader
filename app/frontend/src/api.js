export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

async function request(path, options = {}) {
  const isForm = options.body instanceof FormData;
  const headers = isForm ? undefined : { "Content-Type": "application/json" };

  const response = await fetch(path, {
    credentials: "same-origin",
    headers,
    ...options,
  });

  if (!response.ok) {
    let detail = `HTTP ${response.status}`;
    try {
      const data = await response.json();
      if (data && data.detail) {
        detail =
          typeof data.detail === "string"
            ? data.detail
            : JSON.stringify(data.detail);
      }
    } catch {
      /* non-JSON error body */
    }
    throw new ApiError(response.status, detail);
  }

  if (response.status === 204) return null;
  const type = response.headers.get("content-type") || "";
  return type.includes("application/json") ? response.json() : response.text();
}

const enc = encodeURIComponent;

export const api = {
  session: () => request("/api/session"),
  login: (password) =>
    request("/api/login", {
      method: "POST",
      body: JSON.stringify({ password }),
    }),
  logout: () => request("/api/logout", { method: "POST" }),
  status: () => request("/api/status"),

  files: (path = "") => request(`/api/files?path=${enc(path)}`),
  mkdir: (path, name) =>
    request("/api/files/mkdir", {
      method: "POST",
      body: JSON.stringify({ path, name }),
    }),
  remove: (path, recursive = false) =>
    request("/api/files/delete", {
      method: "POST",
      body: JSON.stringify({ path, recursive }),
    }),
  rename: (path, name) =>
    request("/api/files/rename", {
      method: "POST",
      body: JSON.stringify({ path, name }),
    }),
  upload: (path, file) => {
    const form = new FormData();
    form.append("path", path);
    form.append("file", file, file.name);
    return request("/api/files/upload", { method: "POST", body: form });
  },
  fileUrl: (path) => `/api/files/download?path=${enc(path)}`,

  vpnOptions: () => request("/api/vpn"),
  vpnConnect: (country) =>
    request("/api/vpn/connect", {
      method: "POST",
      body: JSON.stringify({ country: country || null }),
    }),
  vpnDisconnect: () => request("/api/vpn/disconnect", { method: "POST" }),
  vpnKillswitch: (enabled) =>
    request("/api/vpn/killswitch", {
      method: "POST",
      body: JSON.stringify({ enabled }),
    }),
  vpnLeaktest: () => request("/api/vpn/leaktest"),

  jobs: () => request("/api/jobs"),
  startJob: (url, filename) =>
    request("/api/jobs", {
      method: "POST",
      body: JSON.stringify({ url, filename: filename || null }),
    }),
  cancelJob: (id) => request(`/api/jobs/${enc(id)}/cancel`, { method: "POST" }),
  removeJob: (id) => request(`/api/jobs/${enc(id)}`, { method: "DELETE" }),
};
