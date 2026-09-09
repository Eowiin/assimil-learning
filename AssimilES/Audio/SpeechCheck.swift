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

    private let wanted = Locale(identifier: "es-ES")
    /// La locale effectivement réservée, une fois la préparation faite : on ne
    /// refait pas le travail à chaque phrase.
    private var reserved: Locale?

    /// `nil` quand la reconnaissance n'a rien rendu — un silence, ou un échec.
    @discardableResult
    func recognize(_ url: URL) async -> String? {
        do {
            let locale = try await prepareModel()
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
            status = .failed(message(for: error))
            return nil
        }
    }

    func reset() { status = .idle }

    // MARK: - Le modèle espagnol

    /// Prépare le modèle et rend la locale exacte à employer.
    ///
    /// **Une app doit d'abord « réserver » la locale.** Sans cette souscription, le
    /// système refuse jusqu'à dire où en est le téléchargement — « is not subscribed
    /// to transcription.es ». L'outil en ligne de commande (`tools/transcribe.swift`)
    /// n'y était pas soumis, une app l'est : c'est la seule différence entre les deux
    /// usages du même moteur.
    private func prepareModel() async throws -> Locale {
        if let ready = reserved { return ready }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw Failure.unsupportedLocale
        }

        let already = await AssetInventory.reservedLocales.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        if !already {
            guard try await AssetInventory.reserve(locale: locale) else {
                throw Failure.cannotReserve
            }
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .unsupported:
            throw Failure.unsupportedLocale
        case .supported, .downloading:
            // Le modèle se télécharge une fois, puis reste sur l'appareil.
            status = .installingModel
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            break
        }

        reserved = locale
        return locale
    }

    private enum Failure: LocalizedError {
        case unsupportedLocale
        case cannotReserve

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale:
                "L'espagnol n'est pas disponible pour la reconnaissance sur cet appareil."
            case .cannotReserve:
                "Impossible de réserver le modèle espagnol "
                    + "(\(AssetInventory.maximumReservedLocales) langues au maximum)."
            }
        }
    }

    private func message(for error: Error) -> String {
        (error as? Failure)?.errorDescription
            ?? "Reconnaissance impossible : \(error.localizedDescription)"
    }
}
