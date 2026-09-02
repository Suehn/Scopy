cask "scopy" do
  version "0.77.1"
  sha256 "80cad121cef7f73f198910f4cbda77a12f6f70a9fed189a0e302c93da466c64f"

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
