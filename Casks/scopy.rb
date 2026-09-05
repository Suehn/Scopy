cask "scopy" do
  version "0.80.2"
  sha256 "086ddf8efad4980c56977979ddfea7bd6ad0c2c83068fb5387b1cf6bc0bc942a"

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
