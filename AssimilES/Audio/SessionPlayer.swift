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
    /// Ce qui est joué. Le lecteur ne connaît plus « la leçon en cours » : une
    /// séance peut en traverser plusieurs, et c'est l'étape qui porte la sienne.
    @Published private(set) var request: SessionRequest?
    /// Temps réellement écouté dans la séance en cours.
    @Published private(set) var playedSeconds: Double = 0
    /// Temps écouté pas encore versé à la série de jours, toutes séances confondues.
    private var ledger = PlayTimeLedger()

    @Published var rate: Float = 1.0 {
        didSet { timePitch.rate = max(0.5, min(2.0, rate)) }
    }

    var currentStep: SessionStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isFinished: Bool { !steps.isEmpty && index >= steps.count }

    /// Numéro de la phrase en cours, y compris pendant la pause qui la suit :
    /// l'affichage doit continuer de la surligner pendant qu'Ethan la répète.
    var currentSentenceNumber: Int? { currentStep?.sentenceNumber }

    /// Leçon de l'étape en cours — pas celle de la séance, qui peut en couvrir
    /// plusieurs (la vague en enchaîne deux, la révision autant que nécessaire).
    var currentLessonNumber: Int? { currentStep?.lessonNumber }

    /// L'étape « visible » : pendant une pause, la phrase que l'on est en train
    /// de répéter. C'est elle que l'écran surligne et que le drapeau marque.
    var currentNavigableIndex: Int? {
        guard steps.indices.contains(index) else { return nil }
        let i = startOfCurrentSentence()
        return steps[i].isNavigable ? i : nil
    }

    var currentNavigableStep: SessionStep? {
        currentNavigableIndex.map { steps[$0] }
    }

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
    /// Début de la phrase en cours — sa première répétition, pas l'étape : c'est à
    /// la phrase que s'applique « elle vient de commencer ».
    private var sentenceStartedAt: Date?

    init() {
        engine.attach(node)
        engine.attach(timePitch)
    }

    // MARK: - Cycle de vie d'une séance

    /// Les étapes sont fournies déjà construites : c'est l'appelant qui sait de
    /// quoi la séance est faite (une leçon, deux, ou une file de phrases
    /// marquées), et le lecteur n'a plus qu'à les enchaîner.
    func start(_ request: SessionRequest, steps: [SessionStep], from stepIndex: Int = 0) {
        stop()
        self.request = request
        self.steps = steps
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

    /// Le temps écouté depuis le dernier appel. Chaque seconde n'est rendue qu'une
    /// fois : un écran qui disparaît puis réapparaît sur la même séance ne la
    /// recompte pas.
    func takeUnrecordedSeconds() -> Double {
        ledger.takeUnrecorded()
    }

    /// Rend la sortie audio à autre chose — l'essai de prononciation, qui a besoin
    /// du micro et donc d'une autre catégorie de session. Le moteur est arrêté et
    /// son format oublié : il se reconnecte tout seul à la lecture suivante.
    func releaseAudio() {
        pause()
        if engine.isRunning { engine.stop() }
        connectedFormat = nil
    }

    func stop() {
        isPlaying = false
        cancelScheduled()
        steps = []
        index = 0
        request = nil
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
    /// Avec plusieurs répétitions, la phrase repart de sa première.
    func previousOrReplay() {
        guard !steps.isEmpty else { return }
        let elapsed = sentenceStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0
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
        SessionNavigation.startOfSentence(at: index, in: steps)
    }

    private func navigableIndex(after i: Int) -> Int? {
        SessionNavigation.navigableIndex(after: i, in: steps)
    }

    private func navigableIndex(before i: Int) -> Int? {
        SessionNavigation.navigableIndex(before: i, in: steps)
    }

    // MARK: - Diffusion

    private func scheduleCurrentStep() {
        guard isPlaying, let step = currentStep else {
            if isPlaying { finish() }
            return
        }

        if step.isNavigable { sentenceStartedAt = .now }
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
            ledger.add(step.duration)
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

/// Le temps écouté, versé une seule fois à la série de jours.
struct PlayTimeLedger {
    private(set) var total: Double = 0
    private var recorded: Double = 0

    mutating func add(_ seconds: Double) {
        guard seconds > 0 else { return }
        total += seconds
    }

    mutating func takeUnrecorded() -> Double {
        let pending = total - recorded
        recorded = total
        return pending
    }
}

/// Les sauts de phrase en phrase, sans moteur audio : ce qui se calcule se teste.
enum SessionNavigation {
    /// Première étape de la phrase en cours : depuis une pause ou une répétition,
    /// on remonte à la première écoute de la phrase plutôt que de rejouer du silence.
    static func startOfSentence(at index: Int, in steps: [SessionStep]) -> Int {
        guard !steps.isEmpty else { return 0 }
        var i = min(max(0, index), steps.count - 1)
        while i > 0, !steps[i].isNavigable { i -= 1 }
        return i
    }

    static func navigableIndex(after i: Int, in steps: [SessionStep]) -> Int? {
        guard steps.indices.contains(i) else { return nil }
        var j = i + 1
        while j < steps.count {
            if steps[j].isNavigable, !steps[j].isSameSentence(as: steps[i]) || !steps[i].isNavigable {
                return j
            }
            j += 1
        }
        return nil
    }

    static func navigableIndex(before i: Int, in steps: [SessionStep]) -> Int? {
        var j = min(i, steps.count) - 1
        while j >= 0 {
            if steps[j].isNavigable { return j }
            j -= 1
        }
        return nil
    }
}
