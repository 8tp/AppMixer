import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var audioManager: AudioManager
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(newValue)
                    }
                    .font(.system(size: 13))

                Divider()

                Text("Pinned Apps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                if audioManager.pinnedApps.isEmpty {
                    Text("No pinned apps. Right-click an app in the mixer to pin it.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(audioManager.pinnedApps), id: \.self) { bundleID in
                        HStack {
                            Text(displayName(for: bundleID))
                                .font(.system(size: 12))
                            Spacer()
                            Button("Remove") {
                                var pinned = audioManager.pinnedApps
                                pinned.remove(bundleID)
                                audioManager.setPinnedApps(pinned)
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("About Per-App Volume")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text("On macOS 14+, AppMixer uses CoreAudio process objects to detect audio apps. Per-app volume control requires a HAL audio driver plugin. Volume slider values are saved and will apply when a compatible audio driver is installed.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 350, height: 380)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func displayName(for bundleID: String) -> String {
        let components = bundleID.split(separator: ".")
        return String(components.last ?? Substring(bundleID))
    }
}
