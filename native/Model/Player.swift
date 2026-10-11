import AVFoundation
import Observation

/// Plays one recording at a time: the reference song, a note preview, or a take.
@MainActor @Observable final class Player {
    private(set) var playing = false
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var title = ""
    /// The data-relative path of what is loaded; identifies the take being played.
    private(set) var source: String?
    private(set) var waveform: [Double] = []
    var volume = 0.9 { didSet { player?.volume = Float(volume) } }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

    var isLoaded: Bool { player != nil }

    func load(_ url: URL, source: String, title: String, waveform: [Double] = []) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = Float(volume)
        player.prepareToPlay()
        self.player = player
        self.source = source
        self.title = title
        self.waveform = waveform
        duration = player.duration
        position = 0
    }

    func play() {
        guard let player else { return }
        if position >= duration - 0.1 { player.currentTime = 0; position = 0 }
        player.play()
        playing = true
        // The clock only runs while there is something to show.
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        playing = false
        ticker?.invalidate()
        ticker = nil
    }

    func toggle() { playing ? pause() : play() }

    func seek(_ time: Double) {
        guard let player else { return }
        position = min(max(0, time), duration)
        player.currentTime = position
    }

    /// Unloads the recording, for example before its file is deleted.
    func stop() {
        pause()
        player = nil
        source = nil
        title = ""
        waveform = []
        position = 0
        duration = 0
    }

    private func tick() {
        guard let player else { return }
        if player.isPlaying {
            position = player.currentTime
        } else {
            // Reached the end.
            position = duration
            pause()
        }
    }
}
