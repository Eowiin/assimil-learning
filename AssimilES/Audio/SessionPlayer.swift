import Foundation
import AVFoundation

/// Joue une séance étape par étape.
///
/// Choix structurant : les pauses de répétition sont jouées comme du **silence
/// audible** plutôt qu'attendues avec un minuteur. iOS suspend une app en
/// arrière-plan dès que sa session audio cesse de produire du son ; une pause de
/// 6 secondes en mode minuteur suffirait à faire mourir la séance dans la poche.
/// En diffusant du silence, le flux ne s'interrompt jamais et l'app reste vivante.
@MainActor
final class SessionPlayer: ObservableObject {

    @Published private(set) var steps: [SessionStep] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var lesson: Lesson?
    @Published private(set) var mode: StudyMode = .passive
    /// Temps réellement écouté, pour alimenter la série de jours.
    @Published private(set) var playedSeconds: Double = 0

    @Published var rate: Float = 1.0 {
        didSet { timePitch.rate = max(0.5, min(2.0, rate)) }
    }

    var currentStep: SessionStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isFinished: Bool { !steps.isEmpty && index >= steps.count }

    /// Numéro de la phrase en cours, y compris pendant la pause qui la suit :
    /// l'affichage doit continuer de la surligner pendant qu'Ethan la répète.
    var currentSentenceNumber: Int? { currentStep?.sentenceNumber }

    var onStepChanged: ((SessionStep?) -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    /// Format avec lequel le graphe est actuellement connecté.
    private var connectedFormat: AVAudioFormat?
    /// Format servant à fabriquer les buffers de silence, connu dès le début de
    /// la séance même si la première étape n'est pas un fichier.
    private var silenceFormat: AVAudioFormat?
    /// Invalide les callbacks des étapes annulées par un saut ou une pause.
    private var generation = 0
    private var stepStartedAt: Date?

    init() {
        engine.attach(node)
        engine.attach(timePitch)
    }

    // MARK: - Cycle de vie d'une séance

    func start(mode: StudyMode, lesson: Lesson, settings: SessionSettings, from stepIndex: Int = 0) {
        stop()
        self.mode = mode
        self.lesson = lesson
        self.steps = SessionBuilder.build(mode: mode, lesson: lesson, settings: settings)
        self.index = min(max(0, stepIndex), max(0, steps.count - 1))
        self.playedSeconds = 0
        guard !steps.isEmpty else { return }
        adoptFormatFromFirstClip()
        play()
    }

    func play() {
        guard !steps.isEmpty, !isFinished else { return }
        activateSession()
        isPlaying = true
        scheduleCurrentStep()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        cancelScheduled()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func stop() {
        isPlaying = false
        cancelScheduled()
        steps = []
        index = 0
        lesson = nil
    }

    // MARK: - Navigation

    /// Rejoue la phrase en cours depuis son début.
    func replayCurrent() {
        guard !steps.isEmpty else { return }
        index = startOfCurrentSentence()
        restartPlayback()
    }

    /// Comportement standard d'un lecteur : revenir en arrière relance la phrase
    /// en cours, sauf si elle vient de commencer — auquel cas on remonte à la
    /// précédente. Au casque, la triple pression tombe donc naturellement sur
    /// « refais-la moi », qui est le geste le plus fréquent en répétition.
    func previousOrReplay() {
        guard !steps.isEmpty else { return }
        let elapsed = stepStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        let atStart = elapsed < 1.5

        if atStart, let previous = navigableIndex(before: startOfCurrentSentence()) {
            index = previous
        } else {
            index = startOfCurrentSentence()
        }
        restartPlayback()
    }

    func nextSentence() {
        guard !steps.isEmpty else { return }
        guard let next = navigableIndex(after: index) else {
            finish()
            return
        }
        index = next
        restartPlayback()
    }

    func seek(to stepIndex: Int) {
        guard steps.indices.contains(stepIndex) else { return }
        index = stepIndex
        restartPlayback()
    }

    private func restartPlayback() {
        cancelScheduled()
        onStepChanged?(currentStep)
        if isPlaying {
            scheduleCurrentStep()
        }
    }

    /// Première étape de la phrase en cours : depuis une pause, on remonte à la
    /// phrase qu'elle suit plutôt que de rejouer du silence.
    private func startOfCurrentSentence() -> Int {
        var i = min(index, steps.count - 1)
        while i > 0, !steps[i].isNavigable { i -= 1 }
        return i
    }

    private func navigableIndex(after i: Int) -> Int? {
        var j = i + 1
        while j < steps.count {
            if steps[j].isNavigable, steps[j].sentenceNumber != steps[i].sentenceNumber || !steps[i].isNavigable {
                return j
            }
            j += 1
        }
        return nil
    }

    private func navigableIndex(before i: Int) -> Int? {
        var j = i - 1
        while j >= 0 {
            if steps[j].isNavigable { return j }
            j -= 1
        }
        return nil
    }

    // MARK: - Diffusion

    private func scheduleCurrentStep() {
        guard isPlaying, let step = currentStep else {
            if isPlaying { finish() }
            return
        }

        stepStartedAt = .now
        onStepChanged?(step)
        let token = generation

        switch step.kind {
        case .pause:
            scheduleSilence(seconds: step.duration, token: token)
        default:
            guard let url = step.url else { advance(token: token); return }
            scheduleFile(at: url, token: token)
        }
    }

    private func scheduleFile(at url: URL, token: Int) {
        guard let file = try? AVAudioFile(forReading: url) else {
            advance(token: token)
            return
        }
        guard prepareEngine(for: file.processingFormat) else {
            advance(token: token)
            return
        }
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.advance(token: token) }
        }
        node.play()
    }

    private func scheduleSilence(seconds: Double, token: Int) {
        guard let format = silenceFormat, prepareEngine(for: format) else {
            advance(token: token)
            return
        }
        let frames = AVAudioFrameCount(max(0.1, seconds) * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            advance(token: token)
            return
        }
        buffer.frameLength = frames
        // Un buffer fraîchement alloué n'est pas garanti nul : on l'efface pour
        // ne pas diffuser un résidu mémoire dans les oreilles.
        for channel in 0..<Int(format.channelCount) {
            if let data = buffer.floatChannelData?[channel] {
                data.update(repeating: 0, count: Int(frames))
            }
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.advance(token: token) }
        }
        node.play()
    }

    /// Le format audio doit être connu avant la première pause : sans ça, une
    /// pause tombant avant tout fichier serait silencieusement sautée, faute de
    /// format pour fabriquer le silence.
    private func adoptFormatFromFirstClip() {
        guard let url = steps.compactMap(\.url).first,
              let file = try? AVAudioFile(forReading: url)
        else { return }
        silenceFormat = file.processingFormat
    }

    private func advance(token: Int) {
        // Étape annulée entre-temps par un saut, une pause ou un arrêt.
        guard token == generation, isPlaying else { return }

        if let step = currentStep, !step.isPause {
            playedSeconds += step.duration
        }
        index += 1
        if index >= steps.count {
            finish()
        } else {
            scheduleCurrentStep()
        }
    }

    private func finish() {
        isPlaying = false
        cancelScheduled()
        index = steps.count
        onStepChanged?(nil)
    }

    private func cancelScheduled() {
        generation &+= 1
        node.stop()
    }

    // MARK: - Moteur

    /// Connecte le graphe à la première lecture, avec le format réel des fichiers.
    /// Toutes les pistes partagent le même format (44,1 kHz mono, produit par
    /// tools/build-audio.sh) ; le cas d'un format différent est traité par sûreté.
    @discardableResult
    private func prepareEngine(for newFormat: AVAudioFormat) -> Bool {
        if connectedFormat != newFormat {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(node, to: timePitch, format: newFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: newFormat)
            connectedFormat = newFormat
            silenceFormat = newFormat
        }
        guard !engine.isRunning else { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            print("moteur audio indisponible : \(error)")
            return false
        }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .spokenAudio : traitement adapté à la parole, et respect des
            // réglages système pour l'audio parlé (voiture, casque).
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            print("session audio indisponible : \(error)")
        }
    }
}
