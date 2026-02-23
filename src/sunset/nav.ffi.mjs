export function set_hash(hash) {
  window.location.hash = "#" + hash;
}

export function get_hash() {
  const h = window.location.hash;
  // Strip leading "#"
  return h.startsWith("#") ? h.slice(1) : "";
}

export function clear_hash() {
  // Remove hash without triggering a scroll — use replaceState
  history.replaceState(null, "", window.location.pathname + window.location.search);
}

export function on_hash_change(callback) {
  window.addEventListener("hashchange", () => {
    callback(get_hash());
  });
}
