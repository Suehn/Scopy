cask "scopy" do
  version "0.82.2"
  sha256 "35f0c1e050fbffa2a3f79854d6b16960e9c3e5abfb99d2f12ea17ad8a9b10988"

  url "https://github.com/Suehn/Scopy/releases/download/v#{version}/Scopy-#{version}.dmg"
  name "Scopy"
  desc "Clipboard manager with unlimited history"
  homepage "https://github.com/Suehn/Scopy"

  depends_on macos: ">= :sonoma"

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
