import Foundation
import Speech
import AVFoundation

/// Repasse une prise dans la reconnaissance vocale espagnole, en local.
///
/// Même moteur et même modèle que la transcription du corpus
/// (`tools/transcribe.swift`) : `SpeechTranscriber`, modèle es-ES installé une
/// fois, **rien ne sort du téléphone**. L'ancienne API `SFSpeechRecognizer`
/// basculait sur les serveurs d'Apple faute de modèle local ; ici il s'agit de la
/// voix d'Ethan, ce qui est une raison de plus de rester hors ligne.
///
/// Ce que ça mesure, et ce que ça ne mesure pas : la reconnaissance dit si les mots
/// **passent**, pas si l'accent est bon. Aucune API d'Apple n'évalue une
/// prononciation. Un résultat parfait veut dire « la machine t'a compris », ce qui
/// est déjà le signal utile — c'est celui qui a fait ressortir `Ejem` comme le seul
/// mot manqué sur les cinq leçons de contrôle.
@MainActor
final class SpeechCheck: ObservableObject {

    enum Status: Equatable {
        case idle
        case installingModel
        case working
        case done(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let locale = Locale(identifier: "es-ES")

    /// `nil` quand la reconnaissance n'a rien rendu — un silence, ou un échec.
    @discardableResult
    func recognize(_ url: URL) async -> String? {
        do {
            try await installModelIfNeeded()
            status = .working

            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [transcriber],
                                          options: .init(priority: .high,
                                                         modelRetention: .processLifetime))
            let file = try AVAudioFile(forReading: url)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }

            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                status = .failed("Rien n'a été reconnu.")
                return nil
            }
            status = .done(text)
            return text
        } catch {
            status = .failed("Reconnaissance impossible : \(error.localizedDescription)")
            return nil
        }
    }

    func reset() { status = .idle }

    /// Le modèle espagnol se télécharge une fois, puis reste sur l'appareil.
    private func installModelIfNeeded() async throws {
        let installed = await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe])
        else { return }
        if !installed { status = .installingModel }
        try await request.downloadAndInstall()
    }
}
