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
//	cascade-setup.exe --uninstall          remove registry keys and files
package main

import (
	"bufio"
	"crypto/sha256"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

//go:embed payload
var payload embed.FS

const (
	hostName     = "com.cascade.host"
	defaultExtID = "kamlaafhjnegfjdbnfajbanjfkemefga" // ID when loaded from the repo path on the dev Mac
)

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
	flag.Parse()

	root := filepath.Join(os.Getenv("LOCALAPPDATA"), "Cascade")
	bin := filepath.Join(root, "bin")
	ext := filepath.Join(root, "extension")

	if *uninstall {
		doUninstall(root)
		pause()
		return
	}

	fmt.Println("Cascade dev setup")
	fmt.Println("  installing to", root)
	must(extractDir("payload/bin", bin))
	must(extractDir("payload/extension", ext))

	// Native messaging host manifest. Authorize: the ID Chrome derives for the
	// extension folder we just extracted, the dev-Mac ID, and any given ID.
	ids := []string{unpackedIDForPath(ext), defaultExtID}
	if *extID != "" {
		ids = append(ids, *extID)
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

	app := filepath.Join(bin, "cascade_app", "cascade_app.exe") // Flutter UI, if bundled
	if _, err := os.Stat(app); err != nil {
		app = filepath.Join(bin, "cascade-gui.exe")
	}
	if !*noAuto {
		if err := regAdd(`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "Cascade", fmt.Sprintf(`"%s" --background`, app)); err != nil {
			fmt.Println("  ! autostart:", err)
		} else {
			fmt.Println("  autostart: on (hidden, tray icon)")
		}
	}

	fmt.Println()
	fmt.Println("Next, in your browser:")
	fmt.Println("  1. chrome://extensions  ->  Developer mode  ->  Load unpacked  ->")
	fmt.Println("     ", ext)
	fmt.Println("  2. If the extension's Options page shows an ID other than")
	fmt.Println("     ", ids[0], " run:  cascade-setup.exe --extension-id <ID>")
	fmt.Println("  3. Download anything: choose Cascade in the popup.")
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
	for _, k := range browserKeys {
		_ = exec.Command("reg", "delete", k, "/f").Run()
	}
	_ = exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "Cascade", "/f").Run()
	_ = exec.Command("taskkill", "/IM", "cascade-gui.exe", "/F").Run()
	_ = exec.Command("taskkill", "/IM", "cascade_app.exe", "/F").Run()
	if err := os.RemoveAll(root); err != nil {
		fmt.Println("  !", err)
	}
	fmt.Println("  done (downloads and the token in %APPDATA%\\cascade were left in place)")
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
