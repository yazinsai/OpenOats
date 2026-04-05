cask "openoats" do
  version "1.44.1"
  sha256 "3570196d9339bd2b00752885dcfc96e4cecca4b7e86f6a8aa7423821e94d84aa"

  url "https://github.com/yazinsai/OpenOats/releases/download/v#{version}/OpenOats.dmg"
  name "OpenOats"
  desc "Real-time meeting copilot"
  homepage "https://github.com/yazinsai/OpenOats"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "OpenOats.app"

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
