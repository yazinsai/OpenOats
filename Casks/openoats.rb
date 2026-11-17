cask "openoats" do
  version "2.1.1"
  sha256 "5d041139f8953eb274832a0590baefa8c070b8c6cc836f85f0d75c392b2af158"

  url "https://github.com/yazinsai/OpenOats/releases/download/v#{version}/OpenOats.dmg"
  name "OpenOats"
  desc "Minimal meeting recorder that turns calls into markdown notes and transcripts"
  homepage "https://github.com/yazinsai/OpenOats"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  # Homebrew uses major releases; the app bundle requires macOS 14.2+.
  depends_on macos: :sonoma

  app "OpenOats.app"

  # Application Support/OpenOats holds the Meetings working folders (audio) and on-device models.
  # Meeting files in the notes folder (~/Documents/OpenOats by default) are user data and stay.
  zap trash: [
    "~/Library/Application Support/OpenOats",
    "~/Library/Caches/com.openoats.app",
    "~/Library/HTTPStorages/com.openoats.app",
    "~/Library/Preferences/com.openoats.app.plist",
    "~/Library/Saved Application State/com.openoats.app.savedState",
    "~/Library/Caches/com.opengranola.app",
    "~/Library/HTTPStorages/com.opengranola.app",
    "~/Library/Preferences/com.opengranola.app.plist",
    "~/Library/Saved Application State/com.opengranola.app.savedState",
  ]
end
