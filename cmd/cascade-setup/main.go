//go:build windows

// Command cascade-setup is a single-file Windows dev installer. It embeds the
// prebuilt binaries and the browser extension (populated into payload/ by
// scripts/build-windows.sh), extracts them to %LOCALAPPDATA%\Cascade,
// registers the browser native-messaging host in the registry, adds an
// autostart entry, and launches the app. No PowerShell, no repo checkout.
//
//	cascade-setup.exe                      install + launch
//	cascade-setup.exe --extension-id ID    also authorize this extension ID
//	cascade-setup.exe --no-autostart       skip the Run-key entry
//	cascade-setup.exe --force              allow installing an older version
//	cascade-setup.exe --no-ui              install without the Flutter UI (development only)
//	cascade-setup.exe --uninstall          remove registry keys and files
//
// Running it again reinstalls the same version or upgrades an older one; an
// older setup than the installed version is refused unless --force.
package main

import (
	"bufio"
	"crypto/sha256"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"cascade/internal/bundle"
	"cascade/internal/version"
)

//go:embed payload
var payload embed.FS

const (
	hostName     = "com.cascade.host"
	defaultExtID = "kamlaafhjnegfjdbnfajbanjfkemefga" // ID when loaded from the repo path on the dev Mac
	// Add/Remove Programs entry; shared with the NSIS installer so each
	// detects what the other installed.
	uninstallKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Cascade`
)

const firefoxExtID = "cascade@d3xt3r.dev"
const firefoxHostKey = `HKCU\Software\Mozilla\NativeMessagingHosts\` + hostName

var browserKeys = []string{
	`HKCU\Software\Google\Chrome\NativeMessagingHosts\` + hostName,
	`HKCU\Software\Chromium\NativeMessagingHosts\` + hostName,
	`HKCU\Software\Microsoft\Edge\NativeMessagingHosts\` + hostName,
	`HKCU\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\` + hostName,
}

func main() {
	extID := flag.String("extension-id", "", "additionally authorize this extension ID (from the extension's Options page)")
	noAuto := flag.Bool("no-autostart", false, "do not start Cascade at login")
	uninstall := flag.Bool("uninstall", false, "remove Cascade")
	noLaunch := flag.Bool("no-launch", false, "do not start the app after installing")
	force := flag.Bool("force", false, "install even if a newer version is installed")
	noUI := flag.Bool("no-ui", false, "install the command-line pieces even though this setup carries no Flutter UI (development only)")
	flag.Parse()

	root := filepath.Join(os.Getenv("LOCALAPPDATA"), "Cascade")
	bin := filepath.Join(root, "bin")
	ext := filepath.Join(root, "extension")

	if *uninstall {
		doUninstall(root)
		pause()
		return
	}

	fmt.Println("Cascade setup", version.Version)
	if !bundle.HasWindowsUI(payload, "payload") && !*noUI {
		fmt.Println("  This setup was packaged without the Flutter UI (bin\\cascade_app), so it")
		fmt.Println("  would install a Cascade you cannot open. Build the UI on Windows with")
		fmt.Println("  scripts\\flutter-windows.ps1 -CopyTo <checkout>, then ./build windows on the Mac.")
		fmt.Println("  To install only the command-line pieces anyway, run with --no-ui.")
		pause()
		os.Exit(1)
	}
	if have := installedVersion(); have != "" {
		switch c := version.Compare(have, version.Version); {
		case c > 0 && !*force:
			fmt.Printf("  Cascade %s is installed and this setup is %s; downgrades are not supported.\n", have, version.Version)
			fmt.Println("  Uninstall first (cascade-setup.exe --uninstall) or run with --force.")
			pause()
			os.Exit(1)
		case c > 0:
			fmt.Printf("  downgrading %s -> %s (--force)\n", have, version.Version)
		case c == 0:
			fmt.Printf("  Cascade %s is already installed; reinstalling (settings and downloads are kept)\n", have)
		default:
			fmt.Printf("  upgrading %s -> %s\n", have, version.Version)
		}
	}
	// Windows will not overwrite a running executable.
	stopApp()

	fmt.Println("  installing to", root)
	_ = os.Remove(filepath.Join(bin, "cascade-gui.exe")) // pre-0.4.0 UI
	must(extractDir("payload/bin", bin))
	must(extractDir("payload/extension", ext))

	// Native messaging host manifest. Authorize: the ID Chrome derives for the
	// extension folder we just extracted, the dev-Mac ID, the store IDs when
	// the extension is published, and any given ID.
	chromeID, edgeID := storeIDs()
	ids := []string{unpackedIDForPath(ext), defaultExtID}
	for _, id := range []string{chromeID, edgeID, *extID} {
		if id != "" {
			ids = append(ids, id)
		}
	}
	manifestPath := filepath.Join(bin, hostName+".json")
	must(writeManifest(manifestPath, filepath.Join(bin, "cascade-host.exe"), ids))
	fmt.Println("  host manifest:", manifestPath)
	for _, k := range browserKeys {
		if err := regAdd(k, "", manifestPath); err != nil {
			fmt.Println("  ! registry:", k, err)
		} else {
			fmt.Println("  registered:", k)
		}
	}
	// Firefox: fixed add-on ID; its manifest is keyed by allowed_extensions.
	ffPath := filepath.Join(bin, hostName+".firefox.json")
	must(writeFirefoxManifest(ffPath, filepath.Join(bin, "cascade-host.exe")))
	if err := regAdd(firefoxHostKey, "", ffPath); err != nil {
		fmt.Println("  ! registry:", firefoxHostKey, err)
	} else {
		fmt.Println("  registered:", firefoxHostKey)
	}

	// Published extension: each browser installs it from its store on next
	// start (Chrome shows a one-time "Enable extension" prompt).
	registerStoreExtension(chromeID, edgeID)

	app := filepath.Join(bin, "cascade_app", "cascade_app.exe")
	if _, err := os.Stat(app); err != nil {
		fmt.Println("  ! no Flutter UI installed (--no-ui): the app will not start until bin\\cascade_app is built and copied in")
	} else if *noUI {
		fmt.Println("  ! --no-ui: keeping the previously installed UI at", app, "(not from this setup)")
	}
	if !*noAuto {
		if err := regAdd(`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "Cascade", fmt.Sprintf(`"%s" --background`, app)); err != nil {
			fmt.Println("  ! autostart:", err)
		} else {
			fmt.Println("  autostart: on (hidden, tray icon)")
		}
	}

	// Add/Remove Programs entry (also what the next setup reads to compare
	// versions); the uninstaller is a copy of this setup.
	self, _ := os.Executable()
	setupCopy := filepath.Join(root, "cascade-setup.exe")
	if self != "" && !strings.EqualFold(self, setupCopy) {
		if err := copyFile(self, setupCopy); err != nil {
			fmt.Println("  ! uninstaller copy:", err)
		}
	}
	for name, val := range map[string]string{
		"DisplayName":     "Cascade",
		"DisplayVersion":  version.Version,
		"Publisher":       "d3xt3r",
		"InstallLocation": root,
		"UninstallString": fmt.Sprintf(`"%s" --uninstall`, setupCopy),
	} {
		if err := regAdd(uninstallKey, name, val); err != nil {
			fmt.Println("  ! registry:", name, err)
		}
	}

	fmt.Println()
	if chromeID != "" {
		fmt.Println("Next: restart your browser. It installs the Cascade extension from the")
		fmt.Println("store by itself; click Enable when it asks. Then download anything.")
	} else {
		fmt.Println("Next, in your browser:")
		fmt.Println("  1. chrome://extensions  ->  Developer mode  ->  Load unpacked  ->")
		fmt.Println("     ", ext)
		fmt.Println("  2. If the extension's Options page shows an ID other than")
		fmt.Println("     ", ids[0], " run:  cascade-setup.exe --extension-id <ID>")
		fmt.Println("  3. Download anything: choose Cascade in the popup.")
	}
	fmt.Println()
	if !*noLaunch {
		fmt.Println("  starting", filepath.Base(app))
		cmd := exec.Command(app)
		_ = cmd.Start()
	}
	pause()
}

func doUninstall(root string) {
	fmt.Println("Removing Cascade")
	for _, k := range append(browserKeys, firefoxHostKey) {
		_ = exec.Command("reg", "delete", k, "/f").Run()
	}
	_ = exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "Cascade", "/f").Run()
	_ = exec.Command("reg", "delete", uninstallKey, "/f").Run()
	chromeID, edgeID := storeIDs()
	for _, k := range storeExtensionKeys(chromeID, edgeID) {
		_ = exec.Command("reg", "delete", k, "/f").Run()
	}
	stopApp()
	if err := os.RemoveAll(root); err != nil {
		// The running uninstaller copy cannot delete itself; everything else is gone.
		fmt.Println("  !", err)
	}
	fmt.Println("  done (settings, the token in %APPDATA%\\cascade and downloads were left in place)")
}

// storeIDs reads the store listing IDs bundled as payload/bin/store-ids.env
// (empty until the extension is published).
func storeIDs() (chrome, edge string) {
	b, err := payload.ReadFile("payload/bin/store-ids.env")
	if err != nil {
		return "", ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok || strings.HasPrefix(k, "#") {
			continue
		}
		switch k {
		case "CHROME_WEBSTORE_ID":
			chrome = strings.TrimSpace(v)
		case "EDGE_ADDONS_ID":
			edge = strings.TrimSpace(v)
		}
	}
	return chrome, edge
}

// storeExtensionKeys lists the per-browser registry keys that tell each
// browser to install the extension from its store.
func storeExtensionKeys(chromeID, edgeID string) []string {
	var keys []string
	if chromeID != "" {
		for _, b := range []string{`Google\Chrome`, `Chromium`, `BraveSoftware\Brave-Browser`} {
			keys = append(keys, `HKCU\Software\`+b+`\Extensions\`+chromeID)
		}
	}
	if edgeID != "" {
		keys = append(keys, `HKCU\Software\Microsoft\Edge\Extensions\`+edgeID)
	}
	return keys
}

func registerStoreExtension(chromeID, edgeID string) {
	for _, k := range storeExtensionKeys(chromeID, edgeID) {
		url := "https://clients2.google.com/service/update2/crx"
		if strings.Contains(k, `\Edge\`) {
			url = "https://edge.microsoft.com/extensionwebstorebase/v1/crx"
		}
		if err := regAdd(k, "update_url", url); err != nil {
			fmt.Println("  ! extension registration:", k, err)
		} else {
			fmt.Println("  extension registered:", k)
		}
	}
}

// stopApp ends any running Cascade UI so its files can be replaced or removed
// (cascade-gui.exe was the UI of installs before 0.4.0).
func stopApp() {
	for _, exe := range []string{"cascade_app.exe", "cascade-gui.exe"} {
		_ = exec.Command("taskkill", "/IM", exe, "/F").Run()
	}
}

// installedVersion reads DisplayVersion from the Add/Remove Programs entry
// written by this setup or the NSIS installer; "" when not installed.
func installedVersion() string {
	out, err := exec.Command("reg", "query", uninstallKey, "/v", "DisplayVersion").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) >= 3 && f[0] == "DisplayVersion" {
			return f[len(f)-1]
		}
	}
	return ""
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func extractDir(src, dst string) error {
	return fs.WalkDir(payload, src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, filepath.FromSlash(p))
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := payload.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o755)
	})
}

func writeManifest(path, hostExe string, ids []string) error {
	origins := make([]string, 0, len(ids))
	for _, id := range ids {
		origins = append(origins, "chrome-extension://"+id+"/")
	}
	b, err := json.MarshalIndent(map[string]any{
		"name":            hostName,
		"description":     "Cascade download manager native host",
		"path":            hostExe,
		"type":            "stdio",
		"allowed_origins": origins,
	}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

func writeFirefoxManifest(path, hostExe string) error {
	b, err := json.MarshalIndent(map[string]any{
		"name":               hostName,
		"description":        "Cascade download manager native host",
		"path":               hostExe,
		"type":               "stdio",
		"allowed_extensions": []string{firefoxExtID},
	}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

// regAdd sets a REG_SZ value (name "" = the key's default value) via reg.exe,
// avoiding any non-stdlib dependency.
func regAdd(key, name, value string) error {
	args := []string{"add", key}
	if name == "" {
		args = append(args, "/ve")
	} else {
		args = append(args, "/v", name)
	}
	args = append(args, "/t", "REG_SZ", "/d", value, "/f")
	out, err := exec.Command("reg", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// unpackedIDForPath mirrors how Chrome derives an unpacked extension's ID:
// SHA-256 of the absolute path, first 16 bytes, each nibble as a letter a-p.
// Chrome's path normalization can differ from this; the Options page shows
// the real ID and --extension-id authorizes it explicitly.
func unpackedIDForPath(p string) string {
	sum := sha256.Sum256([]byte(p))
	var b strings.Builder
	for _, c := range sum[:16] {
		b.WriteByte('a' + c>>4)
		b.WriteByte('a' + c&0x0f)
	}
	return b.String()
}

func must(err error) {
	if err != nil {
		fmt.Println("  ! error:", err)
		pause()
		os.Exit(1)
	}
}

func pause() {
	fmt.Print("\nPress Enter to close.")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}
