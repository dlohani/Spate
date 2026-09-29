// Safari only (manifest.safari.json). Safari has no downloads API, so a
// download cannot be intercepted after it starts; instead, clicks on links
// that are clearly files are handed to Cascade before the navigation. If the
// app declines (not running, refused), the click falls back to the browser.
//
// "Clearly a file": the link has a download attribute, or its path ends in a
// common binary/archive/media extension. Other links are never touched.
(() => {
  const FILE_RE = /\.(zip|rar|7z|tar|gz|tgz|bz2|xz|iso|img|dmg|pkg|exe|msi|deb|rpm|apk|mp4|mkv|avi|mov|webm|mp3|flac|wav|m4a|pdf|epub|bin|jar)$/i;

  document.addEventListener(
    "click",
    (ev) => {
      if (ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
      const a = ev.target && ev.target.closest && ev.target.closest("a[href]");
      if (!a) return;
      const url = a.href;
      if (!/^https?:/i.test(url)) return;
      let path = "";
      try {
        path = new URL(url).pathname;
      } catch (e) {
        return;
      }
      if (!a.hasAttribute("download") && !FILE_RE.test(path)) return;

      ev.preventDefault();
      ev.stopImmediatePropagation();
      chrome.runtime.sendMessage({ type: "link", url, referrer: location.href }, (r) => {
        if (chrome.runtime.lastError || !r || !r.ok) {
          // Not handed off: let the browser do what it would have done.
          if (a.target === "_blank") window.open(url, "_blank");
          else location.href = url;
        }
      });
    },
    true,
  );
})();
