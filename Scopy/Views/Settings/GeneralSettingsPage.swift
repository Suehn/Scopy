import SwiftUI
import ScopyKit

struct GeneralSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .general) {
            SettingsSection(
                "搜索",
                systemImage: "magnifyingglass",
                footer: "建议默认使用 Fuzzy+（与主界面默认一致）。Regex 适合高级用法，但可能更慢。"
            ) {
                SettingsCardRow {
                    LabeledContent("默认搜索模式") {
                        Picker("", selection: $tempSettings.defaultSearchMode) {
                            Text("精确（Exact）").tag(SearchMode.exact)
                            Text("模糊（Fuzzy）").tag(SearchMode.fuzzy)
                            Text("分词模糊（Fuzzy+）").tag(SearchMode.fuzzyPlus)
                            Text("正则（Regex）").tag(SearchMode.regex)
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
