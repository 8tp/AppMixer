import SwiftUI

struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject var audioManager: AudioManager

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 20, height: 20)
                .cornerRadius(4)

            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)

            Slider(
                value: Binding(
                    get: { app.volume },
                    set: { audioManager.setAppVolume(app, volume: $0) }
                ),
                in: 0...1
            )
            .controlSize(.small)

            Text("\(Int(app.volume * 100))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .opacity(app.isActive ? 1.0 : 0.5)
        .animation(.easeOut(duration: 0.3), value: app.isActive)
        .contextMenu {
            Button(audioManager.isPinned(app) ? "Unpin App" : "Pin App") {
                audioManager.togglePin(app)
            }
        }
    }
}
