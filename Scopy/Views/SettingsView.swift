import SwiftUI

/// 设置窗口视图
/// v0.4: 实现用户可配置的设置界面
struct SettingsView: View {
    @State private var tempSettings: SettingsDTO
    @State private var isSaving = false

    /// 窗口引用，用于关闭窗口
    var onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        _tempSettings = State(initialValue: AppState.shared.settings)
    }

    var body: some View {
        Form {
            // MARK: - History Section
            Section {
                Picker("Maximum Items", selection: $tempSettings.maxItems) {
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                    Text("100,000").tag(100000)
                }
                .pickerStyle(.menu)
            } header: {
                Label("History", systemImage: "clock.arrow.circlepath")
            } footer: {
                Text("Older items will be automatically removed when the limit is exceeded.")
                    .foregroundStyle(.secondary)
            }

            // MARK: - Storage Section
            Section {
                Picker("Maximum Storage", selection: $tempSettings.maxStorageMB) {
                    Text("100 MB").tag(100)
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                }
                .pickerStyle(.menu)

                Toggle("Save Images", isOn: $tempSettings.saveImages)
                Toggle("Save Files", isOn: $tempSettings.saveFiles)
            } header: {
                Label("Storage", systemImage: "internaldrive")
            } footer: {
                Text("Disabling image/file saving will skip these content types.")
                    .foregroundStyle(.secondary)
            }

            // MARK: - About Section
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("0.4")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Database Location")
                    Spacer()
                    Text("~/Library/Application Support/Scopy/")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
        .safeAreaInset(edge: .bottom) {
            // MARK: - Action Buttons
            HStack {
                Button("Reset to Defaults") {
                    tempSettings = .default
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") {
                    onDismiss?()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveSettings()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .onAppear {
            // 刷新设置以确保最新
            tempSettings = AppState.shared.settings
        }
    }

    private func saveSettings() {
        isSaving = true
        Task {
            await AppState.shared.updateSettings(tempSettings)
            await MainActor.run {
                isSaving = false
                onDismiss?()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
