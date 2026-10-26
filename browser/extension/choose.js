// Prompt shown when a download starts and the mode is "ask". The browser's own
// download keeps running while this is open, so "Use the browser" (or closing
// the window) loses nothing; only "Download with Spate" hands it off.
const params = new URLSearchParams(location.search);
const id = Number(params.get("d"));

(async () => {
  const stored = await chrome.storage.session.get("pending:" + id);
  const item = stored["pending:" + id];
  if (!item) {
    document.getElementById("file").textContent = "This download is no longer pending.";
    document.getElementById("spate").disabled = true;
    return;
  }
  document.getElementById("file").textContent = item.filename || item.url;
  document.getElementById("host").textContent = item.url;
  document.getElementById("hostShort").textContent = item.host;

  const decide = async (choice) => {
    // scope: "all" makes this the standing default (one-time ask), "site"
    // remembers it for this host only, "none" applies to this download only.
    const scope = document.querySelector('input[name="scope"]:checked')?.value ?? "none";
    await chrome.runtime.sendMessage({ type: "choice", id, choice, scope, item });
    window.close();
  };
  document.getElementById("spate").addEventListener("click", () => decide("spate"));
  document.getElementById("browser").addEventListener("click", () => decide("browser"));
})();
