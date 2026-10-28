cask "hearsay" do
  version "0.1.4"
  sha256 "9fcfaf5fe430b551e7ee6be7ea3ff2a83716135c47074985339e4664ba2fa69f"

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
