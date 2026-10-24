cask "hearsay" do
  version "0.1.0"
  sha256 "6541d6d4c72fd945558b7b08dbcffebf372c4f0fc3dbfb0171e5ef6d7d65036e"

  url "https://github.com/vrennat/hearsay/releases/download/v#{version}/Hearsay-#{version}.zip"
  name "Hearsay"
  desc "Local meeting recorder and speaker-labelled transcriber"
  homepage "https://github.com/vrennat/hearsay"

  livecheck do
    url :url
    strategy :github_latest
  end

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
