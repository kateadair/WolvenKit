import AVFoundation
import Combine
import SwiftUI

struct AudioPreviewControl: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    private let playbackClock = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: togglePlayback) {
                    Label(isPlaying ? "Pause Preview" : "Play Preview", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(player == nil)

                Slider(value: $currentTime, in: 0...max(duration, 1), onEditingChanged: { editing in
                    if !editing { seek(to: currentTime) }
                })
                .disabled(player == nil || duration <= 0)

                Text("\(timeLabel(currentTime)) / \(timeLabel(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 82, alignment: .trailing)
            }
            .accessibilityElement(children: .contain)
            Text("Playback uses macOS-supported audio formats.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
            isPlaying = false
            currentTime = 0
            duration = 0
        }
        .onReceive(playbackClock) { _ in
            guard let player else { return }
            let time = player.currentTime().seconds
            if time.isFinite { currentTime = max(0, time) }
            let total = player.currentItem?.duration.seconds ?? 0
            if total.isFinite { duration = max(0, total) }
            isPlaying = player.timeControlStatus == .playing
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
