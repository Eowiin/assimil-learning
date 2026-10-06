import Foundation
import Combine

/// Écoute une réponse dite à voix haute et la rend en texte, sans quitter l'appareil.
///
/// Enregistrer impose la catégorie de session `.playAndRecord` : on n'enregistre donc
/// qu'à l'arrêt, sur l'écran d'exercice, et la sortie audio est rendue à la séance
/// dès la prise terminée (voir `VoiceRecorder`).
@MainActor
final class AnswerListener: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording(key: String)
        case recognizing(key: String)
        case installingModel(key: String)
        case failed(key: String, message: String)

        var key: String? {
            switch self {
            case .idle: nil
            case .recording(let key), .recognizing(let key), .installingModel(let key), .failed(let key, _): key
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    private let recorder = VoiceRecorder()
    private let speech: SpeechCheck
    private var statusWatch: AnyCancellable?

    init(locale: Locale) {
        speech = SpeechCheck(locale: locale)
    }

    /// Une prise ou une reconnaissance est en cours, pour cet élément ou un autre.
    var isBusy: Bool {
        switch phase {
        case .recording, .recognizing, .installingModel: true
        case .idle, .failed: false
        }
    }

    func start(_ key: String, releasing player: SessionPlayer) async {
        guard !isBusy else { return }
        player.releaseAudio()
        recorder.takeOver()
        await recorder.startRecording(at: Self.url(for: key))
        if recorder.isRecording {
            phase = .recording(key: key)
        } else {
            recorder.handBack()
            phase = .failed(key: key, message: recorder.micDenied
                ? "Micro non autorisé : Réglages → Assimil ES → Micro."
                : "Enregistrement impossible.")
        }
    }

    /// Arrête la prise et rend ce qui a été compris ; `nil` si rien ne l'a été, le
    /// motif restant affiché dans `phase`.
    func finish() async -> String? {
        guard case .recording(let key) = phase, let url = recorder.stopRecording() else { return nil }
        recorder.handBack()
        phase = .recognizing(key: key)

        // Le premier usage d'une langue télécharge son modèle : on le dit plutôt que
        // de laisser « Reconnaissance… » tourner une minute.
        statusWatch = speech.$status.sink { [weak self] status in
            guard status == .installingModel else { return }
            Task { @MainActor in
                guard let self, self.phase == .recognizing(key: key) else { return }
                self.phase = .installingModel(key: key)
            }
        }
        let heard = await speech.recognize(url)
        statusWatch = nil
        try? FileManager.default.removeItem(at: url)

        if let heard {
            phase = .idle
            return heard
        }
        if case .failed(let message) = speech.status {
            phase = .failed(key: key, message: message)
        } else {
            phase = .idle
        }
        return nil
    }

    func cancel() {
        if case .recording = phase { _ = recorder.stopRecording() }
        if isBusy || phase != .idle { recorder.handBack() }
        phase = .idle
    }

    private static func url(for key: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reponse-\(key).m4a")
    }
}
