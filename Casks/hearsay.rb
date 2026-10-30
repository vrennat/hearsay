cask "hearsay" do
  version "0.1.7"
  sha256 "53c7a0db73a22d34b44d9ad2c3ef3ec35a83989292ace8a3161d22c02e35f787"

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
