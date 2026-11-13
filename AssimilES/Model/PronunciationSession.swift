import Foundation
import Observation

/// Ce que la séance demande à l'audio : enregistrer une prise, la réécouter en
/// entier ou par mot, jouer le natif. `PronunciationAudio` (dans `Audio/`) passe par
/// `VoiceRecorder` ; les tests, par un faux.
@MainActor
protocol PronunciationSound: AnyObject {
    func begin()
    func end()
    /// Faux si le micro est refusé.
    func startRecording() async -> Bool
    func stopRecording() -> Data?
    func playNative(_ url: URL, onFinish: @escaping @MainActor () -> Void)
    /// La dernière prise, ou un passage seulement (un mot), en secondes.
    func playTake(range: ClosedRange<Double>?, onFinish: @escaping @MainActor () -> Void)
    func stopPlayback()
}

/// Une séance de prononciation : cinq phrases, une faute détaillée à la fois
/// (`docs/module-prononciation.md`). La règle est ici, l'écran affiche.
@Observable
@MainActor
final class PronunciationSession {

    enum Phase: Equatable {
        /// La phrase attend d'être lue.
        case ready
        case recording
        /// Le serveur juge la prise.
        case judging
        /// Le jugement est affiché.
        case judged
        /// Un échec : on garde la prise pour la renvoyer.
        case failed(String)
        case micDenied
        /// Les cinq phrases sont passées : le bilan.
        case finished
    }

    enum Playing: Equatable { case none, native, take, word }

    let sentences: [DrillSentence]
    let startedAt: Date
    private(set) var index = 0
    private(set) var phase: Phase = .ready
    /// La phrase affichée, mot par mot, avec le jugement de la dernière prise.
    private(set) var words: [DisplayedWord] = []
    private(set) var result: PronunciationResult?
    /// Les prises jugées sur la phrase en cours.
    private(set) var attempts = 0
    /// Le mot touché, dont on montre le détail. Nil : la première faute.
    var selectedWord: Int?
    private(set) var playing: Playing = .none
    /// Le dernier jugement de chaque phrase passée, pour le bilan.
    private(set) var judgedSentences: [(sentence: DrillSentence, result: PronunciationResult)] = []

    private let service: any PronunciationService
    private let sound: any PronunciationSound
    private let nativeURL: (DrillSentence) -> URL?
    /// Appelé à chaque prise jugée : l'écran la garde (`PronunciationRecord`).
    private let onJudged: (DrillSentence, Int, PronunciationResult) -> Void
    /// La prise qui a échoué, à renvoyer telle quelle.
    private var pendingTake: Data?

    init(sentences: [DrillSentence], service: any PronunciationService, sound: any PronunciationSound,
         nativeURL: @escaping (DrillSentence) -> URL?,
         onJudged: @escaping (DrillSentence, Int, PronunciationResult) -> Void = { _, _, _ in },
         startedAt: Date = .now) {
        self.onJudged = onJudged
        self.sentences = sentences
        self.service = service
        self.sound = sound
        self.nativeURL = nativeURL
        self.startedAt = startedAt
        if sentences.isEmpty { phase = .finished }
        showSentence()
    }

    var current: DrillSentence? { index < sentences.count ? sentences[index] : nil }

    // MARK: - La faute détaillée

    /// Le mot dont on montre le détail : celui qu'on a touché, sinon le premier
    /// fautif, sinon le premier qui a un indice.
    var focusWord: DisplayedWord? {
        if let selectedWord, let word = words.first(where: { $0.id == selectedWord }), word.judged != nil {
            return word
        }
        return words.first(where: \.isFault) ?? words.first(where: \.hasHint)
    }

    /// Le son détaillé : la première faute du mot, sinon son indice. Une faute dans un
    /// mot qu'on n'a pas pu rattacher se dit quand même, sans mot souligné.
    var focusPhone: JudgedPhone? {
        if let word = focusWord?.judged {
            return word.phonemes.first(where: \.fault) ?? word.phonemes.first(where: \.hint)
        }
        return result?.words.lazy.flatMap(\.phonemes).first(where: \.fault)
    }

    /// On passe à la suivante sans faute, ou après une nouvelle tentative, même
    /// ratée (décision 3 du plan).
    var canAdvance: Bool {
        guard phase == .judged, let result else { return false }
        return !result.hasFault || attempts >= 2
    }

    var isLast: Bool { index >= sentences.count - 1 }

    /// Les sons fautifs de la séance, du plus fréquent au plus rare.
    var summary: [(symbol: String, count: Int)] {
        let faults = judgedSentences.flatMap { $0.result.words.flatMap(\.phonemes) }.filter(\.fault)
        let counts = Dictionary(grouping: faults, by: \.expected).mapValues(\.count)
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.symbol < $1.symbol }
    }

    // MARK: - Les gestes

    func open() { sound.begin() }

    func close() {
        if phase == .recording { _ = sound.stopRecording() }
        stopPlayback()
        sound.end()
    }

    /// Le bouton micro : un premier appui écoute, un second envoie. Depuis un
    /// jugement, il relance la même phrase.
    func toggleMic() async {
        switch phase {
        case .ready, .judged, .micDenied:
            stopPlayback()
            phase = await sound.startRecording() ? .recording : .micDenied
        case .recording:
            guard let take = sound.stopRecording(), !take.isEmpty else {
                phase = result == nil ? .ready : .judged
                return
            }
            await judge(take)
        case .judging, .failed, .finished:
            break
        }
    }

    /// Abandonner une prise en cours, sans l'envoyer.
    func cancelRecording() {
        guard phase == .recording else { return }
        _ = sound.stopRecording()
        phase = result == nil ? .ready : .judged
    }

    func retry() async {
        guard case .failed = phase, let pendingTake else { return }
        await judge(pendingTake)
    }

    /// La phrase suivante, ou le bilan. Depuis un échec, on peut passer la phrase.
    func next() {
        let failed: Bool = if case .failed = phase { true } else { false }
        guard canAdvance || failed, let current else { return }
        stopPlayback()
        if let result { judgedSentences.append((current, result)) }
        index += 1
        if index >= sentences.count {
            phase = .finished
        } else {
            showSentence()
        }
    }

    func select(_ word: DisplayedWord) {
        guard word.judged != nil else { return }
        selectedWord = word.id
    }

    // MARK: - L'écoute

    func playNative() {
        guard let current, let url = nativeURL(current), phase != .recording else { return }
        toggle(.native) { sound.playNative(url, onFinish: $0) }
    }

    func playTake() {
        guard result != nil, phase != .recording else { return }
        toggle(.take) { sound.playTake(range: nil, onFinish: $0) }
    }

    /// Le mot détaillé, découpé dans la prise, avec un peu de marge pour l'entendre.
    func playFocusWord() {
        guard let range = focusWord?.judged?.timeRange, phase != .recording else { return }
        let padded = max(0, range.lowerBound - 0.08)...(range.upperBound + 0.08)
        toggle(.word) { sound.playTake(range: padded, onFinish: $0) }
    }

    func stopPlayback() {
        sound.stopPlayback()
        playing = .none
    }

    // MARK: - Le reste

    private func toggle(_ what: Playing, start: (@escaping @MainActor () -> Void) -> Void) {
        if playing == what { return stopPlayback() }
        sound.stopPlayback()
        playing = what
        start { [weak self] in
            guard let self, self.playing == what else { return }
            self.playing = .none
        }
    }

    private func showSentence() {
        words = current.map { PronunciationMatch.attach([], to: $0.text) } ?? []
        result = nil
        attempts = 0
        selectedWord = nil
        pendingTake = nil
        if current != nil { phase = .ready }
    }

    private func judge(_ take: Data) async {
        guard let current else { return }
        phase = .judging
        pendingTake = take
        do {
            let judged = try await service.judge(audio: take, text: current.text)
            result = judged
            words = PronunciationMatch.attach(judged.words, to: current.text)
            attempts += 1
            onJudged(current, attempts, judged)
            selectedWord = nil
            pendingTake = nil
            phase = .judged
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
