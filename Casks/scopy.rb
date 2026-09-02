cask "scopy" do
  version "0.75.0"
  sha256 "a22d391ff01b0a94506758513b17659eaa9f04f0cc261268f6bf1c0b56e6a9c8"

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
