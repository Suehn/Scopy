cask "scopy" do
  version "0.58.fix2"
  sha256 "93058ee088d47e871c88892f430645c562249b75facb553f6ca8efc20e072161"

  url "https://github.com/Suehn/Scopy/releases/download/v#{version}/Scopy-#{version}.dmg"
  name "Scopy"
  desc "Native macOS clipboard manager with unlimited history"
  homepage "https://github.com/Suehn/Scopy"

  depends_on macos: ">= :sonoma"

  app "Scopy.app"

  caveats <<~EOS
    Scopy is not signed. On first launch:
    Right-click the app → Open → Open
  EOS

  zap trash: [
    "~/Library/Application Support/Scopy",
    "~/Library/Preferences/com.scopy.app.plist",
  ]
end
