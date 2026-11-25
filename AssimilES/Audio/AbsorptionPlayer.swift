import AVFoundation
import Observation

/// La voix du texte du bloc 2 : une phrase, ou toutes à la suite depuis l'une d'elles.
/// Un simple `AVAudioPlayer` sur les fichiers de `AbsorptionAudio` ; la session audio
/// reste celle de l'app (`.playback`).
@Observable
@MainActor
final class AbsorptionPlayer: NSObject, AVAudioPlayerDelegate {
    /// La phrase qu'on entend.
    private(set) var playing: Int?
    /// Vrai en lecture continue (« Tout écouter »).
    private(set) var continuous = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var url: (Int) -> URL? = { _ in nil }
    @ObservationIgnored private var count = 0

    /// Lit la phrase `index`, puis les suivantes si `continuous`.
    func play(_ index: Int, count: Int, continuous: Bool, url: @escaping (Int) -> URL?) {
        self.url = url
        self.count = count
        self.continuous = continuous
        start(index)
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        continuous = false
    }

    private func start(_ index: Int) {
        player?.stop()
        guard index < count else { return stop() }
        guard let file = url(index), let next = try? AVAudioPlayer(contentsOf: file) else {
            // Une phrase sans voix : on passe à la suivante en lecture continue.
            return continuous ? start(index + 1) : stop()
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        next.delegate = self
        player = next
        playing = index
        next.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard player === self.player, let current = playing else { return }
            if continuous { start(current + 1) } else { stop() }
        }
    }
}
