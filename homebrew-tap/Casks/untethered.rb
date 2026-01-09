cask "untethered" do
  version "1.0"
  sha256 "PLACEHOLDER_SHA256"

  url "https://github.com/reifying/untethered/releases/download/v#{version}/Untethered-#{version}-mac.zip"
  name "Untethered"
  desc "Voice control interface for Claude Code"
  homepage "https://github.com/reifying/untethered"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Untethered.app"

  zap trash: [
    "~/Library/Application Support/Untethered",
    "~/Library/Caches/dev.910labs.voice-code-mac",
    "~/Library/Preferences/dev.910labs.voice-code-mac.plist",
  ]
end
