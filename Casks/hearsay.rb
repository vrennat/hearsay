cask "hearsay" do
  version "0.1.6"
  sha256 "0f7c9781afbe934832fda923cb00a66682d396dc033bb4fe03ace1112873f26d"

  url "https://github.com/vrennat/hearsay/releases/download/v#{version}/Hearsay-#{version}.zip"
  name "Hearsay"
  desc "Local meeting recorder and speaker-labelled transcriber"
  homepage "https://github.com/vrennat/hearsay"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Hearsay.app"
  binary "#{appdir}/Hearsay.app/Contents/MacOS/hearsay-cli", target: "hearsay"

  zap trash: [
    "~/Library/Application Support/FluidAudio",
    "~/Library/Logs/Hearsay.log",
    "~/Library/Preferences/com.tannervass.hearsay.plist",
  ]

  caveats <<~EOS
    Meetings live in ~/Meetings. Neither uninstall nor zap ever removes that folder.
  EOS
end
