// Prompt shown when a download starts and the mode is "ask". The browser's own
// download keeps running while this is open, so "Use the browser" (or closing
// the window) loses nothing; only "Download with Cascade" hands it off.
const params = new URLSearchParams(location.search);
const id = Number(params.get("d"));

(async () => {
  const stored = await chrome.storage.session.get("pending:" + id);
  const item = stored["pending:" + id];
  if (!item) {
    document.getElementById("file").textContent = "This download is no longer pending.";
    document.getElementById("cascade").disabled = true;
    return;
  }
  document.getElementById("file").textContent = item.filename || item.url;
  document.getElementById("host").textContent = item.url;
  document.getElementById("hostShort").textContent = item.host;

  const decide = async (choice) => {
    const remember = document.getElementById("remember").checked;
    await chrome.runtime.sendMessage({ type: "choice", id, choice, remember, item });
    window.close();
  };
  document.getElementById("cascade").addEventListener("click", () => decide("cascade"));
  document.getElementById("browser").addEventListener("click", () => decide("browser"));
})();
