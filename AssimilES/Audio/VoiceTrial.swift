import Foundation
import Combine

/// Un essai de prononciation sur une phrase : s'enregistrer, se réécouter, voir ce
/// que la reconnaissance a compris et comparer sa mélodie à celle du natif.
///
/// Il vit dans le lecteur : le micro arrête la séance et enregistre d'un même geste,
/// le résultat s'affiche sous la phrase, et « Reprendre » relance la séance là où elle
/// était. La feuille de détail (`PronunciationView`) montre le même essai, courbe
/// comprise.
///
/// **Ce qu'il affirme, et ce qu'il n'affirme pas.** Il ne note pas un accent — aucune
/// API d'Apple ne le fait. Il dit si les mots passent, et de combien la mélodie
/// s'écarte : deux choses mesurables. Le reste est laissé à l'oreille.
///
/// **La sortie audio ne change que sur ce geste.** Enregistrer impose
/// `.playAndRecord` ; la séance la rend (`SessionPlayer.releaseAudio()`) au moment où
/// l'on touche le micro, téléphone en main, et la reprend avec « Reprendre ». Rien ne
/// s'enregistre tout seul pendant les pauses : ce serait risquer la lecture écran
/// verrouillé et valider la voix du natif sans écouteurs.
@MainActor
final class VoiceTrial: ObservableObject {

    enum Phase: Equatable {
        case ready
        case recording
        case analysing
        case done
        case failed(String)
    }

    /// La phrase essayée ; `nil` quand aucun essai n'est ouvert.
    @Published private(set) var step: SessionStep?
    @Published private(set) var phase: Phase = .ready
    /// Les mots de la phrase, ceux qui ne sont pas passés marqués.
    @Published private(set) var verdicts: [WordVerdict] = []
    @Published private(set) var heard: String?
    @Published private(set) var intonation: Intonation?
    @Published private(set) var intonationFailed = false
    @Published private(set) var myDuration: Double = 0

    let recorder = VoiceRecorder()
    let speech = SpeechCheck()
    private var forwards: Set<AnyCancellable> = []

    init() {
        // L'état de lecture et de reconnaissance vit dans ces deux objets : l'écran
        // doit se redessiner quand ils changent.
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwards)
        speech.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwards)
    }

    var isOpen: Bool { step != nil }
    var isRecording: Bool { phase == .recording }
    var reference: String? { step?.sentenceText?.es }
    var canRecord: Bool { reference != nil && step?.markKey != nil }

    /// La dernière prise gardée pour cette phrase, s'il y en a une.
    var myTake: URL? {
        guard let key = step?.markKey, VoiceRecorder.exists(for: key) else { return nil }
        return VoiceRecorder.url(for: key)
    }

    // MARK: - Ouvrir, fermer

    /// Ouvre l'essai sur une phrase et prend la sortie audio. L'appelant a rendu
    /// celle de la séance avant (`SessionPlayer.releaseAudio()`).
    func open(_ step: SessionStep) {
        if self.step?.id != step.id {
            clearResult()
            phase = .ready
        }
        self.step = step
        recorder.takeOver()
        myDuration = myTake.map(VoiceRecorder.duration) ?? 0
    }

    /// Rend la sortie audio. La prise reste sur le disque, une par phrase.
    func close() {
        recorder.handBack()
        step = nil
        phase = .ready
        clearResult()
    }

    // MARK: - Enregistrer

    func toggleRecording() async {
        guard let key = step?.markKey, let reference else { return }

        if recorder.isRecording {
            guard let url = recorder.stopRecording() else { return }
            phase = .analysing
            myDuration = VoiceRecorder.duration(of: url)
            await compareMelody(mine: url)
            if let heard = await speech.recognize(url) {
                self.heard = heard
                verdicts = SpanishMatch.compare(reference: reference, heard: heard)
                phase = .done
            } else if case .failed(let message) = speech.status {
                phase = .failed(message)
            } else {
                phase = .done
            }
        } else {
            clearResult()
            speech.reset()
            await recorder.startRecording(key: key)
            phase = recorder.isRecording ? .recording
                : .failed(recorder.micDenied ? "Micro non autorisé : Réglages → Assimil ES → Micro."
                                             : "Enregistrement impossible.")
        }
    }

    // MARK: - Réécouter

    func toggleNative() {
        if recorder.playing == .native {
            recorder.stopPlayback()
        } else if let url = step?.url {
            recorder.play(url, as: .native)
        }
    }

    func toggleMine() {
        if recorder.playing == .mine {
            recorder.stopPlayback()
        } else if let url = myTake {
            recorder.play(url, as: .mine)
        }
    }

    // MARK: - Ce qui se lit du résultat

    var understoodLabel: String {
        let ok = verdicts.filter(\.isUnderstood).count
        let total = verdicts.count
        if total > 0, ok == total { return "Tous les mots sont passés" }
        return "\(ok) mot\(ok > 1 ? "s" : "") sur \(total) \(ok > 1 ? "sont passés" : "est passé")"
    }

    /// Le tempo compare deux durées, ce qui est mesurable — contrairement à un
    /// jugement sur l'accent. Assimil se dit lentement au début : c'est un repère
    /// utile, pas une faute.
    var tempoLabel: String? {
        guard let step, myDuration > 0, step.duration > 0 else { return nil }
        let percent = Int(((myDuration / step.duration - 1) * 100).rounded())
        if abs(percent) <= 15 { return "Même tempo que le natif" }
        return percent > 0
            ? "\(percent) % plus lent que le natif"
            : "\(-percent) % plus rapide que le natif"
    }

    // MARK: - Calcul

    private func clearResult() {
        verdicts = []
        heard = nil
        intonation = nil
        intonationFailed = false
    }

    /// Le calcul de hauteur est du signal, pas de l'interface : il part sur une
    /// tâche détachée pour ne pas figer l'écran le temps de la phrase.
    private func compareMelody(mine url: URL) async {
        guard let nativeURL = step?.url else { intonationFailed = true; return }
        let result = await Task.detached(priority: .userInitiated) { () -> Intonation? in
            guard let native = PitchTracker.track(nativeURL),
                  let mine = PitchTracker.track(url)
            else { return nil }
            return IntonationComparer.compare(native: native, mine: mine)
        }.value
        intonation = result
        intonationFailed = result == nil
    }
}
