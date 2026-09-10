cask "scopy" do
  version "0.80.5"
  sha256 "d53b6a35b970e06d4b2548c5b72cf48e3091e2a0fa9311ccb6bc311874863f31"

  url "https://github.com/Suehn/Scopy/releases/download/v#{version}/Scopy-#{version}.dmg"
  name "Scopy"
  desc "Clipboard manager with unlimited history"
  homepage "https://github.com/Suehn/Scopy"

  depends_on macos: :sonoma

  app "Scopy.app"

  zap trash: [
    "~/Library/Application Support/Scopy",
    "~/Library/Preferences/com.scopy.app.plist",
  ]

  caveats <<~EOS
    Scopy is not signed. On first launch:
    Right-click the app → Open → Open
  EOS
end
