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

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var startedAt: Date?

    // MARK: - Fichiers

    /// Une prise par phrase, nommée comme la clé de marquage (`L012-S04`) : même
    /// vocabulaire dans toute l'app, et une seule prise à la fois — c'est la
    /// dernière qui vaut.
    static func url(for key: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).m4a")
    }

    static func exists(for key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    static func duration(of url: URL) -> Double {
        (try? AVAudioFile(forReading: url)).map {
            Double($0.length) / $0.processingFormat.sampleRate
        } ?? 0
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
    func startRecording(at target: URL) async {
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
        recorder.record()
        startedAt = .now
        isRecording = true
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard let recorder, isRecording else { return nil }
        recorder.stop()
        isRecording = false
        lastDuration = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        self.recorder = nil
        return recorder.url
    }

    // MARK: - Écoute

    func play(_ url: URL, as kind: Playing) {
        stopPlayback()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.delegate = self
        player.play()
        playing = kind
    }

    func stopPlayback() {
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
        }
    }
}
