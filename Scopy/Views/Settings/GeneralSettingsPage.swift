import SwiftUI
import ScopyKit

struct GeneralSettingsPage: View {
    @Binding var tempSettings: SettingsDTO
    @Binding var launchAtLogin: Bool
    let launchAtLoginRequiresApproval: Bool

    var body: some View {
        SettingsPageContainer(page: .general) {
            SettingsSection("Startup", systemImage: "power") {
                SettingsCardRow {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .accessibilityIdentifier("Settings.LaunchAtLoginToggle")
                }
                if launchAtLoginRequiresApproval {
                    SettingsCardDivider()
                    SettingsCardRow {
                        HStack {
                            Text("Allow Scopy in System Settings > General > Login Items to finish.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") {
                                LaunchAtLogin.openLoginItemsSettings()
                            }
                        }
                    }
                }
            }

            SettingsSection(
                "Search",
                systemImage: "magnifyingglass",
                footer: "Fuzzy+ is recommended and matches the main window default. Regex searches only the most recent 2000 items, for advanced recent-only searches."
            ) {
                SettingsCardRow {
                    LabeledContent("Default search mode") {
                        Picker("", selection: $tempSettings.defaultSearchMode) {
                            Text("Fuzzy+ (tokenized, recommended)").tag(SearchMode.fuzzyPlus)
                            Text("Fuzzy").tag(SearchMode.fuzzy)
                            Text("Exact").tag(SearchMode.exact)
                            Text("Regex (most recent 2000 items only)").tag(SearchMode.regex)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                        .accessibilityIdentifier("Settings.DefaultSearchModePicker")
                    }
                }
            }
        }
    }
}
