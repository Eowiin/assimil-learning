import Foundation

/// L'audio de la conversation, par `VoiceRecorder` : la même session
/// `.playAndRecord` que l'essai de prononciation, haut-parleur par défaut.
/// Les prises et les répliques ne vivent que le temps de la conversation, dans le
/// dossier temporaire.
@MainActor
final class ConversationAudio: ConversationSound {

    private let recorder = VoiceRecorder()
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("conversation", isDirectory: true)

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
        await recorder.startRecording(at: folder.appendingPathComponent("tour.m4a"))
        return !recorder.micDenied && recorder.isRecording
    }

    func stopRecording() -> Data? {
        recorder.stopRecording().flatMap { try? Data(contentsOf: $0) }
    }

    func play(_ audio: Data, onFinish: @escaping @MainActor () -> Void) {
        let url = folder.appendingPathComponent("replique-\(UUID().uuidString).m4a")
        guard (try? audio.write(to: url)) != nil else { return onFinish() }
        recorder.onPlaybackFinished = onFinish
        recorder.play(url, as: .native)
    }

    func stopPlayback() {
        recorder.onPlaybackFinished = nil
        recorder.stopPlayback()
    }
}
