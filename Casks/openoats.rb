cask "openoats" do
  version "1.60.0"
  sha256 "289ec4fa9f75d8816d706e7cf8f4b725ef9dde25ee183229f3bd0fd22f8472d1"

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
