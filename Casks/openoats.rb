cask "openoats" do
  version "1.83.1"
  sha256 "688daddddc66e9a66506ec11886cf6fc5ff24fc2e05df9a0ad19b9da109ae8f3"

  url "https://github.com/yazinsai/OpenOats/releases/download/v#{version}/OpenOats.dmg"
  name "OpenOats"
  desc "Real-time meeting copilot"
  homepage "https://github.com/yazinsai/OpenOats"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

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
