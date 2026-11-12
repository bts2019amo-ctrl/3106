import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    // Mirrors SoundEffects.isEnabled so the effect player reads one source of
    // truth (UserDefaults) while the toggle gets @AppStorage semantics.
    @AppStorage("sound.effects.enabled") private var soundEffectsEnabled = true
    // Gates high-risk experimental flows (Siri AI experimental mode) behind
    // an explicit opt-in; the flows stay hidden until this is on.
    @AppStorage(FeatureVisibility.developerModeStorageKey) private var experimentalFeaturesEnabled = false
    @State private var updateStatus: String?
    @State private var updateURL: URL?
    @State private var isCheckingUpdate = false

    private func checkUpdateManually() {
        isCheckingUpdate = true
        updateStatus = nil
        updateURL = nil
        Task {
            // Manual check ignores the dismissed-version memory: the user
            // explicitly asked, so report the newest release either way.
            let offer = await AppUpdateChecker.checkIgnoringDismissal()
            await MainActor.run {
                isCheckingUpdate = false
                if let offer {
                    updateStatus = language.text("settings.update_new", offer.version)
                    updateURL = offer.url
                } else {
                    updateStatus = language.text("settings.update_latest")
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AppLogo()

                        VStack(alignment: .leading, spacing: 3) {
                            Text("3106").font(.headline)
                            Text(language.text("common.version", appVersion))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(language.text("settings.language")) {
                    Picker(language.text("settings.language"), selection: $languageCode) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    NavigationLink {
                        BackupCenterView()
                    } label: {
                        Label(
                            language.text("backup.title"),
                            systemImage: "externaldrive.badge.timemachine"
                        )
                    }

                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label(
                            language.text("ack.title"),
                            systemImage: "heart.text.square.fill"
                        )
                    }

                    RespringButton()
                } header: {
                    Text(language.text("settings.backup"))
                }

                Section {
                    Toggle(isOn: $soundEffectsEnabled) {
                        Label(
                            language.text("settings.sound_effects"),
                            systemImage: "speaker.wave.2"
                        )
                    }
                } header: {
                    Text(language.text("settings.sound_effects"))
                } footer: {
                    Text(language.text("settings.sound_effects_footer"))
                }

                Section {
                    Button {
                        checkUpdateManually()
                    } label: {
                        HStack {
                            Label(
                                language.text("settings.check_update"),
                                systemImage: "arrow.triangle.down.circle"
                            )
                            Spacer()
                            if isCheckingUpdate {
                                ProgressView().controlSize(.small)
                            } else if let updateStatus {
                                Text(updateStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isCheckingUpdate)

                    if let updateURL {
                        Link(destination: updateURL) {
                            Label(language.text("update.open_github"), systemImage: "safari")
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                } header: {
                    Text(language.text("settings.update_header"))
                } footer: {
                    Text(language.text("settings.update_footer"))
                }

                Section {
                    Toggle(isOn: $experimentalFeaturesEnabled) {
                        Label(
                            language.text("settings.experimental"),
                            systemImage: "flask"
                        )
                    }
                } header: {
                    Text(language.text("settings.experimental_header"))
                } footer: {
                    Text(language.text("settings.experimental_footer"))
                }

                if WallpaperFeatureSupportPolicy.isSupported(
                    major: AppInfo.versionTuple.major
                ) {
                    Section {
                        NavigationLink {
                            WallpaperResetSettingsView()
                        } label: {
                            Label(
                                language.text("wallpaper.reset"),
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                    } header: {
                        Text(language.text("tab.wallpapers"))
                    } footer: {
                        Text(language.text("wallpaper.reset_settings_footer"))
                    }
                }

                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                    LabeledContent(language.text("settings.access_backend"), value: SandboxAccess.backend.displayName)
                    LabeledContent(language.text("settings.app_group"), value: appGroupStatus)
                }

                Section {
                    HStack {
                        Text(language.text("settings.current_version"))
                        Spacer()
                        Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                        .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                    }
                    LabeledContent("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                    LabeledContent("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                    LabeledContent(
                        "iOS 26",
                        value: "\(ExploitSupportPolicy.verifiedIOS26BadQueryRange) · \(ExploitSupportPolicy.verifiedIOS26WorseQueryRange)"
                    )
                    LabeledContent("iOS 27", value: ExploitSupportPolicy.verifiedIOS27Range)
                } header: {
                    Text(language.text("settings.verified_versions"))
                } footer: {
                    Text(language.text("settings.supported_versions_footer"))
                }

                Section(language.text("settings.github")) {
                    if let destination = URL(string: "https://github.com/QuinnTang74/3106.git") {
                        Link(destination: destination) {
                            HStack(spacing: 12) {
                                Label("GitHub", systemImage: "link")
                                Spacer()
                                Text("QuinnTang74/3106")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .tint(AppTheme.accent)
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private var appGroupStatus: String {
        guard SandboxAccess.needsWorseQuery else { return "—" }
        return SandboxAccess.appGroup ?? language.text("settings.app_group_missing")
    }

    }