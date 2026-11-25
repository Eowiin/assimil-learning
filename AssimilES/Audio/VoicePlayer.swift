import AVFoundation
import Observation

/// La voix d'une phrase du bloc 1 (`VoiceCache`) : un simple `AVAudioPlayer`, une phrase
/// à la fois. La session audio reste celle de l'app (`.playback`).
@Observable
@MainActor
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    /// Le fichier qu'on entend.
    private(set) var playing: URL?
    @ObservationIgnored private var player: AVAudioPlayer?

    func play(_ url: URL) {
        player?.stop()
        guard let next = try? AVAudioPlayer(contentsOf: url) else { return stop() }
        try? AVAudioSession.sharedInstance().setActive(true)
        next.delegate = self
        player = next
        playing = url
        next.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard player === self.player else { return }
            stop()
        }
    }
}
