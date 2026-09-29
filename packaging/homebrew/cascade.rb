# Homebrew cask for Cascade. Publish the .pkg (scripts/package-macos.sh) as a
# GitHub release, fill in url/sha256, and host this file in a tap
# (e.g. github.com/<you>/homebrew-cascade), then:  brew install --cask <you>/cascade/cascade
cask "cascade" do
  version "0.4.0"
  sha256 "REPLACE_WITH_SHA256_OF_Cascade-#{version}.pkg"

  url "https://github.com/REPLACE_OWNER/cascade/releases/download/v#{version}/Cascade-#{version}.pkg"
  name "Cascade"
  desc "Download manager with browser capture, parallel connections and resume"
  homepage "https://github.com/REPLACE_OWNER/cascade"

  depends_on macos: ">= :ventura"

  pkg "Cascade-#{version}.pkg"

  uninstall pkgutil: "dev.d3xt3r.cascade",
            launchctl: "dev.d3xt3r.cascade",
            script: {
              executable: "#{Dir.home}/Library/Application Support/cascade/bin/uninstall",
              sudo:       false,
            }

  zap trash: [
    "~/Library/Application Support/cascade",
    "~/Library/LaunchAgents/dev.d3xt3r.cascade.plist",
  ]

  caveats <<~EOS
    Load the browser extension once: chrome://extensions -> Developer mode ->
    Load unpacked -> ~/Library/Application Support/cascade/extension
  EOS
end
