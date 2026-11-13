import Foundation

/// L'audio de la prononciation, par `VoiceRecorder` : la même session
/// `.playAndRecord` que la conversation, haut-parleur par défaut. La prise ne vit
/// que le temps de la séance, dans le dossier temporaire.
@MainActor
final class PronunciationAudio: PronunciationSound {

    private let recorder = VoiceRecorder()
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("prononciation", isDirectory: true)
    private var take: URL { folder.appendingPathComponent("prise.m4a") }

    func begin() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recorder.takeOver()
    }

    func end() {
        recorder.onPlaybackFinished = nil
        recorder.handBack()
        try? FileManager.default.removeItem(at: folder)
    }

    func startRecording() async -> Bool {
        await recorder.startRecording(at: take)
        return !recorder.micDenied && recorder.isRecording
    }

    func stopRecording() -> Data? {
        recorder.stopRecording().flatMap { try? Data(contentsOf: $0) }
    }

    func playNative(_ url: URL, onFinish: @escaping @MainActor () -> Void) {
        recorder.onPlaybackFinished = onFinish
        recorder.play(url, as: .native)
    }

    func playTake(range: ClosedRange<Double>?, onFinish: @escaping @MainActor () -> Void) {
        recorder.onPlaybackFinished = onFinish
        recorder.play(take, as: .mine, range: range)
    }

    func stopPlayback() {
        recorder.onPlaybackFinished = nil
        recorder.stopPlayback()
    }
}

#if DEBUG
/// Le micro des tests d'interface : il « enregistre » sans demander l'autorisation
/// que le simulateur réclamerait, et ne joue rien.
@MainActor
final class SilentPronunciationSound: PronunciationSound {
    func begin() {}
    func end() {}
    func startRecording() async -> Bool { true }
    func stopRecording() -> Data? { Data("silence".utf8) }
    func playNative(_ url: URL, onFinish: @escaping @MainActor () -> Void) { onFinish() }
    func playTake(range: ClosedRange<Double>?, onFinish: @escaping @MainActor () -> Void) { onFinish() }
    func stopPlayback() {}
}
#endif
