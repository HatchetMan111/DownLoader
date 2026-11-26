export function bytes(value) {
  if (!value && value !== 0) return "–";
  if (value === 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const index = Math.min(
    units.length - 1,
    Math.floor(Math.log(value) / Math.log(1024)),
  );
  const scaled = value / 1024 ** index;
  const digits = scaled >= 100 || index === 0 ? 0 : 1;
  return `${scaled.toFixed(digits)} ${units[index]}`;
}

export function speed(value) {
  if (!value) return "";
  return `${bytes(value)}/s`;
}

export function duration(seconds) {
  if (!seconds && seconds !== 0) return "–";
  const total = Math.max(0, Math.floor(seconds));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days > 0) return `${days} T ${hours} Std`;
  if (hours > 0) return `${hours} Std ${minutes} Min`;
  if (minutes > 0) return `${minutes} Min`;
  return `${total} s`;
}

export function dateTime(epoch) {
  if (!epoch) return "–";
  return new Date(epoch * 1000).toLocaleString("de-DE", {
    day: "2-digit",
    month: "2-digit",
    year: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function relative(epoch) {
  if (!epoch) return "–";
  const diff = Math.floor(Date.now() / 1000 - epoch);
  if (diff < 60) return "gerade eben";
  if (diff < 3600) return `vor ${Math.floor(diff / 60)} Min`;
  if (diff < 86400) return `vor ${Math.floor(diff / 3600)} Std`;
  return `vor ${Math.floor(diff / 86400)} T`;
}

export function dirname(path) {
  if (!path) return "";
  const index = path.lastIndexOf("/");
  return index === -1 ? "" : path.slice(0, index);
}

export function basename(path) {
  if (!path) return "";
  const index = path.lastIndexOf("/");
  return index === -1 ? path : path.slice(index + 1);
}
