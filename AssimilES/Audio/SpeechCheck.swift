import Foundation
import Speech
import AVFoundation

/// Repasse une prise dans la reconnaissance vocale espagnole, en local.
///
/// **Deux moteurs, et le second n'est pas un pis-aller théorique.**
/// `SpeechTranscriber` est celui qui a transcrit le corpus
/// (`tools/transcribe.swift`), mais il expose `isAvailable` : il demande un
/// appareil capable d'Apple Intelligence, ce que l'iPhone 11 (A13) n'est pas.
/// `DictationTranscriber` n'a pas cette condition et rend la même chose — un
/// `Result` avec son `text`. On prend le premier quand il est là, le second sinon.
///
/// Dans les deux cas, l'app doit **réserver** la locale auprès d'`AssetInventory`
/// avant d'en toucher les assets. Rien ne sort du téléphone : c'est la voix
/// d'Ethan, ce qui est une raison de plus.
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

    /// Lequel des deux moteurs cet appareil peut faire tourner.
    enum Engine: Equatable {
        case speechTranscriber
        case dictation

        var label: String {
            switch self {
            case .speechTranscriber: "SpeechTranscriber"
            case .dictation: "DictationTranscriber"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    /// Renseigné après la première reconnaissance — l'écran le dit en petit, pour
    /// qu'on sache lequel a parlé.
    @Published private(set) var engine: Engine?

    private let wanted = Locale(identifier: "es-ES")
    /// Moteur et locale retenus une fois la préparation faite : on ne refait pas
    /// ce travail à chaque phrase.
    private var prepared: (engine: Engine, locale: Locale)?

    /// `nil` quand la reconnaissance n'a rien rendu — un silence, ou un échec.
    @discardableResult
    func recognize(_ url: URL) async -> String? {
        do {
            let (engine, locale) = try await prepare()
            self.engine = engine
            status = .working

            let file = try AVAudioFile(forReading: url)
            let text = try await transcribe(file, engine: engine, locale: locale)
                .trimmingCharacters(in: .whitespacesAndNewlines)

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

    // MARK: - Transcription

    private func transcribe(_ file: AVAudioFile, engine: Engine, locale: Locale) async throws -> String {
        // Les deux modules produisent le même contenu mais par des flux de types
        // distincts : la boucle ne se factorise pas, l'analyse si.
        switch engine {
        case .speechTranscriber:
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            try await analyze(module, file: file)
            var text = ""
            for try await result in module.results { text += String(result.text.characters) }
            return text

        case .dictation:
            let module = DictationTranscriber(locale: locale, preset: .shortDictation)
            try await analyze(module, file: file)
            var text = ""
            for try await result in module.results { text += String(result.text.characters) }
            return text
        }
    }

    private func analyze(_ module: any SpeechModule, file: AVAudioFile) async throws {
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .high,
                                                     modelRetention: .processLifetime))
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
    }

    // MARK: - Le modèle espagnol

    private func prepare() async throws -> (Engine, Locale) {
        if let prepared { return (prepared.engine, prepared.locale) }

        // Le moteur du corpus d'abord ; sinon celui qui ne demande rien au matériel.
        let engine: Engine = SpeechTranscriber.isAvailable ? .speechTranscriber : .dictation

        let locale: Locale?
        switch engine {
        case .speechTranscriber:
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        case .dictation:
            // La dictée passe par l'autorisation de reconnaissance vocale, que le
            // moteur récent ne réclamait pas.
            guard await requestSpeechAuthorization() else { throw Failure.notAuthorized }
            locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        }
        guard let locale else { throw Failure.localeUnsupported(engine) }

        // Une app doit « souscrire » à la locale : sans réservation, le système
        // refuse jusqu'à dire où en est le téléchargement.
        let already = await AssetInventory.reservedLocales.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        if !already {
            guard try await AssetInventory.reserve(locale: locale) else {
                throw Failure.cannotReserve
            }
        }

        try await install(engine: engine, locale: locale)

        prepared = (engine, locale)
        return (engine, locale)
    }

    private func install(engine: Engine, locale: Locale) async throws {
        let module: any SpeechModule = switch engine {
        case .speechTranscriber: SpeechTranscriber(locale: locale, preset: .transcription)
        case .dictation: DictationTranscriber(locale: locale, preset: .shortDictation)
        }

        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return
        case .unsupported:
            throw Failure.assetsUnsupported(engine)
        case .supported, .downloading:
            // Le modèle se télécharge une fois, puis reste sur l'appareil.
            status = .installingModel
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            return
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    // MARK: - Échecs

    /// Chaque cause a son message : « pas disponible » sans dire pourquoi obligeait
    /// à deviner lequel des trois obstacles on venait de heurter.
    private enum Failure: LocalizedError {
        case localeUnsupported(Engine)
        case assetsUnsupported(Engine)
        case cannotReserve
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let engine):
                "L'espagnol n'est pas dans les langues de \(engine.label) sur cet appareil."
            case .assetsUnsupported(let engine):
                "Le modèle espagnol de \(engine.label) n'est pas installable sur cet appareil."
            case .cannotReserve:
                "Impossible de réserver le modèle espagnol "
                    + "(\(AssetInventory.maximumReservedLocales) langues au maximum)."
            case .notAuthorized:
                "La reconnaissance vocale n'est pas autorisée pour l'app "
                    + "(Réglages → Assimil ES → Reconnaissance vocale)."
            }
        }
    }

    private func message(for error: Error) -> String {
        (error as? Failure)?.errorDescription
            ?? "Reconnaissance impossible : \(error.localizedDescription)"
    }
}
