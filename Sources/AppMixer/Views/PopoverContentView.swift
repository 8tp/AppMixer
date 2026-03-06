import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var audioManager: AudioManager
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            masterVolumeSection
            Divider().padding(.horizontal, 12)
            appListSection
            Divider().padding(.horizontal, 12)
            bottomBar
        }
        .frame(width: 300, height: 400)
        .sheet(isPresented: $showSettings) {
            SettingsView(audioManager: audioManager)
        }
    }

    // MARK: - Master Volume

    private var masterVolumeSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Master Volume")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { audioManager.toggleMasterMute() }) {
                    Image(systemName: audioManager.isMasterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(audioManager.isMasterMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { audioManager.masterVolume },
                        set: { audioManager.setMasterVolume($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text("\(Int(audioManager.masterVolume * 100))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - App List

    private var appListSection: some View {
        Group {
            if audioManager.audioApps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No audio apps running")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(audioManager.audioApps) { app in
                            AppVolumeRow(app: app, audioManager: audioManager)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.vertical, 6)
                }
                .animation(.easeInOut(duration: 0.3), value: audioManager.audioApps.map(\.id))
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
