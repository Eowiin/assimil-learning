import Foundation
import MediaPlayer

/// Écran verrouillé et commandes du casque.
///
/// La séance doit rester pilotable sans sortir le téléphone : c'est la condition
/// pour travailler en marchant plutôt qu'assis au bureau.
@MainActor
final class NowPlayingController {

    private unowned let player: SessionPlayer

    init(player: SessionPlayer) {
        self.player = player
        configureCommands()
        player.onStepChanged = { [weak self] _ in self?.refreshNowPlaying() }
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.player.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.player.nextSentence()
            return .success
        }
        // Revenir en arrière relance la phrase en cours : au casque, c'est le
        // geste « refais-la moi », de loin le plus fréquent en répétition.
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.player.previousOrReplay()
            return .success
        }
    }

    func refreshNowPlaying() {
        guard let request = player.request, let step = player.currentStep else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        // La leçon de l'étape, pas celle de la séance : la vague en enchaîne
        // deux et la révision en traverse autant qu'il y a de phrases marquées.
        // Prise sur la séance, la ligne de l'écran verrouillé annoncerait la
        // mauvaise leçon la moitié du temps.
        let lessonNumber = step.lessonNumber

        var info: [String: Any] = [
            MPMediaItemPropertyAlbumTitle: "Leçon \(lessonNumber)",
            MPMediaItemPropertyArtist: request.isReview ? request.title : request.subtitle,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        if let n = step.sentenceNumber {
            // Le texte de la phrase quand il est saisi, son numéro sinon : dans
            // les deux cas l'écran verrouillé dit où on en est.
            let spanish = step.sentenceText?.es
            info[MPMediaItemPropertyTitle] = spanish ?? (step.isExercise ? "Exercice \(n)" : "Phrase \(n)")
        } else {
            info[MPMediaItemPropertyTitle] = LessonTextStore.text(for: lessonNumber)?.titleES
                ?? "Leçon \(lessonNumber)"
        }

        info[MPMediaItemPropertyPlaybackDuration] = step.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
