import Foundation
import AVFoundation

/// Enregistre la voix d'Ethan sur une phrase, et rejoue au choix le natif ou sa
/// propre prise.
///
/// **Pourquoi c'est un moment à part, et pas une greffe sur la pause de
/// répétition.** Enregistrer impose la catégorie `.playAndRecord`, alors que toute
/// la séance repose sur `.playback` et sur un flux qui ne s'interrompt jamais (voir
/// SessionPlayer). Changer de catégorie au milieu d'une leçon, c'est risquer
/// exactement la suspension que le silence diffusé évite. L'essai de prononciation
/// se fait donc à l'arrêt, écran en main — ce qu'il suppose de toute façon.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    enum Playing: Equatable { case none, native, mine }

    @Published private(set) var isRecording = false
    @Published private(set) var playing: Playing = .none
    @Published private(set) var micDenied = false
    /// Durée de la dernière prise, pour la comparer au débit du natif.
    @Published private(set) var lastDuration: Double = 0

    /// Appelé quand une lecture va à son terme (pas quand on l'arrête).
    var onPlaybackFinished: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var startedAt: Date?
    /// La fin d'un passage joué seul.
    private var segmentEnd: Task<Void, Never>?
    /// L'écoute des niveaux du micro, jusqu'à l'arrivée de la voix.
    private var metering: Task<Void, Never>?

    // MARK: - Fichiers

    /// Une prise par phrase, nommée par `SessionStep.recordingKey` (`L012-S04`,
    /// l'ancienne clé de phrase marquée, gardée pour ne renommer aucun fichier) ;
    /// une seule prise à la fois — c'est la dernière qui vaut.
    static func url(for key: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).m4a")
    }

    static func exists(for key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    // MARK: - Session audio

    /// Prend la main sur la sortie audio le temps de l'essai. `.defaultToSpeaker`
    /// évite que la lecture parte dans l'écouteur du haut, ce que `.playAndRecord`
    /// fait sinon d'office.
    func takeOver() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }

    /// Rend la sortie à la séance. Le moteur de lecture se reconnecte tout seul au
    /// prochain démarrage.
    func handBack() {
        stopPlayback()
        if isRecording { _ = stopRecording() }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    // MARK: - Enregistrement

    func requestPermission() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        micDenied = !granted
        return granted
    }

    func startRecording(key: String) async {
        await startRecording(at: Self.url(for: key))
    }

    /// Enregistre vers un fichier choisi : une réponse d'exercice n'a pas à
    /// remplacer la prise gardée pour l'essai de prononciation.
    /// `onVoice` : appelé une fois, au début de la voix dans la prise (`VoiceOnsetDetector`).
    func startRecording(at target: URL, onVoice: (@MainActor (Date) -> Void)? = nil) async {
        guard await requestPermission() else { return }
        stopPlayback()

        try? FileManager.default.removeItem(at: target)

        // Le format du corpus : AAC 44,1 kHz mono. Comparer deux prises encodées
        // pareil évite d'attribuer au locuteur ce qui vient de l'encodage.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        guard let recorder = try? AVAudioRecorder(url: target, settings: settings) else { return }
        self.recorder = recorder
        recorder.isMeteringEnabled = onVoice != nil
        recorder.record()
        startedAt = .now
        isRecording = true
        if let onVoice { listen(to: recorder, onVoice: onVoice) }
    }

    private func listen(to recorder: AVAudioRecorder, onVoice: @escaping @MainActor (Date) -> Void) {
        metering?.cancel()
        var detector = VoiceOnsetDetector(startedAt: .now)
        metering = Task { [weak self] in
            while !Task.isCancelled, let self, self.recorder === recorder {
                recorder.updateMeters()
                if let onset = detector.feed(level: recorder.averagePower(forChannel: 0), at: .now) {
                    onVoice(onset)
                    return
                }
                try? await Task.sleep(for: VoiceOnsetDetector.interval)
            }
        }
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard let recorder, isRecording else { return nil }
        metering?.cancel()
        metering = nil
        recorder.stop()
        isRecording = false
        lastDuration = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        self.recorder = nil
        return recorder.url
    }

    // MARK: - Écoute

    /// `range` : un passage seulement, en secondes (un mot de la prise). `rate` : la
    /// vitesse, hauteur gardée (la voix ralentie d'un débutant) ; pas avec `range`.
    func play(_ url: URL, as kind: Playing, range: ClosedRange<Double>? = nil, rate: Float = 1) {
        stopPlayback()
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            onPlaybackFinished?()
            return
        }
        self.player = player
        player.delegate = self
        if rate != 1, range == nil {
            player.enableRate = true
            player.rate = rate
        }
        if let range {
            player.currentTime = max(0, range.lowerBound)
            let length = range.upperBound - range.lowerBound
            segmentEnd = Task { [weak self] in
                try? await Task.sleep(for: .seconds(length))
                guard !Task.isCancelled, let self, self.player === player else { return }
                self.stopPlayback()
                self.onPlaybackFinished?()
            }
        }
        player.play()
        playing = kind
    }

    func stopPlayback() {
        segmentEnd?.cancel()
        segmentEnd = nil
        player?.stop()
        player = nil
        playing = .none
    }
}

extension VoiceRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playing = .none
            self.onPlaybackFinished?()
        }
    }
}
