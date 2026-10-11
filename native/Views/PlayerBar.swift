import SwiftUI

/// Appears along the bottom while a recording is loaded.
struct PlayerBar: View {
    @Bindable var player: Player

    var body: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14)).foregroundStyle(Theme.onAccent)
                    .frame(width: 34, height: 34).background(Theme.accent.gradient, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.playing ? "Pause" : "Play")

            Text(player.title).font(.callout.weight(.medium)).lineLimit(1).frame(width: 170, alignment: .leading)
            Text(clockText(player.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            Group {
                if player.waveform.isEmpty {
                    Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration)).controlSize(.small)
                } else {
                    WaveformView(samples: player.waveform, progress: player.duration > 0 ? player.position / player.duration : 0) {
                        player.seek($0 * player.duration)
                    }
                    .frame(height: 26)
                }
            }
            .frame(maxWidth: .infinity)
            Text(clockText(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)

            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1).controlSize(.small).frame(width: 70).accessibilityLabel("Volume")
            Button { player.stop() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close the player")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: Theme.contentWidth + 40)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }
}
