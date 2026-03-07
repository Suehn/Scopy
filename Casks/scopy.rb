cask "scopy" do
  version "0.60.2"
  sha256 "d32eea47417105215f38073623262753ed911440b0455f8a098c2d9e0a5efbf1"

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
