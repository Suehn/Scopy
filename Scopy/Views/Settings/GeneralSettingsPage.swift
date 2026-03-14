import SwiftUI
import ScopyKit

struct GeneralSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .general) {
            SettingsSection(
                "搜索",
                systemImage: "magnifyingglass",
                footer: "建议默认使用 Fuzzy+（与主界面默认一致）。Regex 仅搜索最近 2000 条，适合高级 recent-only 场景。"
            ) {
                SettingsCardRow {
                    LabeledContent("默认搜索模式") {
                        Picker("", selection: $tempSettings.defaultSearchMode) {
                            Text("分词模糊（Fuzzy+，推荐）").tag(SearchMode.fuzzyPlus)
                            Text("模糊（Fuzzy）").tag(SearchMode.fuzzy)
                            Text("精确（Exact）").tag(SearchMode.exact)
                            Text("正则（Regex，仅最近 2000 条）").tag(SearchMode.regex)
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
