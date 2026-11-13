# Homebrew cask for Spate. Publish the .pkg (scripts/package-macos.sh) as a
# GitHub release, fill in url/sha256, and host this file in a tap
# (e.g. github.com/<you>/homebrew-spate), then:  brew install --cask <you>/spate/spate
cask "spate" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_spate-macos-#{version}.pkg"

  url "https://github.com/dlohani/Spate/releases/download/v#{version}/spate-macos-#{version}.pkg"
  name "Spate"
  desc "Download manager with browser capture, parallel connections and resume"
  homepage "https://github.com/dlohani/Spate"

  depends_on macos: ">= :ventura"

  pkg "spate-macos-#{version}.pkg"

  uninstall pkgutil: "io.opensources.spate",
            launchctl: "io.opensources.spate",
            script: {
              executable: "#{Dir.home}/Library/Application Support/spate/bin/uninstall",
              sudo:       false,
            }

  zap trash: [
    "~/Library/Application Support/spate",
    "~/Library/LaunchAgents/io.opensources.spate.plist",
  ]

  caveats <<~EOS
    Load the browser extension once: chrome://extensions -> Developer mode ->
    Load unpacked -> ~/Library/Application Support/spate/extension
  EOS
end
