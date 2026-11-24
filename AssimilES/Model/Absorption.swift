import Foundation
import Observation
import SwiftData

// Le bloc 2, « Absorption » (`docs/moteur-adaptatif.md`, étape 4c) : le texte du jour,
// écrit pour l'apprenant par `POST /session/generate-input`, et sa voix par `POST /tts`,
// un m4a par phrase. Le texte est gardé dans `StudySession.inputData` ; les audios sur
// le disque (`AbsorptionAudio`), jamais en base. Les mots nouveaux du texte passent
// « vus » et deviennent des cartes (`LexiconWords`).

/// Le texte du jour, tel que la route le rend, gardé tel quel.
struct AbsorptionText: Codable, Equatable, Sendable {
    struct Sentence: Codable, Equatable, Sendable {
        let es: String
        let fr: String
    }

    /// Où trouver un mot nouveau : la place de la phrase (à partir de 0) et le mot tel
    /// qu'il y est écrit, en minuscules.
    struct Occurrence: Codable, Equatable, Sendable {
        let lemma: String
        let sentence: Int
        let form: String
    }

    let text: String
    let sentences: [Sentence]
    let coverage: Double
    let unknownLemmas: [String]
    let newUsed: [String]
    /// Les phrases qui emploient l'objectif, d'après le juge ; nil s'il n'a pas répondu.
    let objectiveHits: [Int]?
    let attempts: Int
    /// Ajouté à l'étape 4c, absent d'un serveur plus ancien.
    let newOccurrences: [Occurrence]?

    private enum CodingKeys: String, CodingKey {
        case text, sentences, coverage, attempts
        case unknownLemmas = "unknown_lemmas", newUsed = "new_used"
        case objectiveHits = "objective_hits", newOccurrences = "new_occurrences"
    }

    func isObjectiveHit(_ index: Int) -> Bool { objectiveHits?.contains(index) == true }

    /// La phrase de chaque mot nouveau employé : celle que donne le serveur, sinon la
    /// première où le lemme est écrit tel quel (un nom, un adjectif au masculin). Un
    /// verbe conjugué sans `new_occurrences` reste sans phrase, donc sans carte.
    var occurrences: [Occurrence] {
        let given = (newOccurrences ?? []).filter { sentences.indices.contains($0.sentence) }
        let found = Set(given.map(\.lemma))
        let searched: [Occurrence] = newUsed.filter { !found.contains($0) }.compactMap { lemma in
            sentences.firstIndex { Self.range(of: lemma, in: $0.es) != nil }
                .map { Occurrence(lemma: lemma, sentence: $0, form: lemma) }
        }
        return given + searched
    }

    /// Les formes des mots nouveaux, à mettre en gras.
    var newForms: [String] { Array(Set(occurrences.map(\.form))).sorted() }

    /// La place d'un mot entier dans une phrase, à partir de `start`, sans tenir compte
    /// de la casse (les accents comptent) : « mar » ne se trouve pas dans « mariposa ».
    static func range(of word: String, in sentence: String,
                      from start: String.Index? = nil) -> Range<String.Index>? {
        guard !word.isEmpty else { return nil }
        var start = start ?? sentence.startIndex
        while start < sentence.endIndex,
              let found = sentence.range(of: word, options: [.caseInsensitive], range: start..<sentence.endIndex) {
            let before = found.lowerBound == sentence.startIndex ? nil : sentence[sentence.index(before: found.lowerBound)]
            let after = found.upperBound == sentence.endIndex ? nil : sentence[found.upperBound]
            if !(before?.isLetter ?? false), !(after?.isLetter ?? false) { return found }
            start = sentence.index(after: found.lowerBound)
        }
        return nil
    }

    /// Les places de ces mots dans la phrase, sans chevauchement, dans l'ordre.
    static func ranges(of words: [String], in sentence: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for word in words {
            var start = sentence.startIndex
            while let found = range(of: word, in: sentence, from: start) {
                if !result.contains(where: { $0.overlaps(found) }) { result.append(found) }
                start = found.upperBound
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }
}

// MARK: - Le serveur

/// Ce que la route attend (`server/app/seance.py`, `InputRequest`).
struct AbsorptionRequest: Encodable, Equatable, Sendable {
    let level: String
    let theme: String
    let objective: ConversationObjective
    let knownLemmas: [String]
    let newLemmas: [String]
    let targetWords: Int

    private enum CodingKeys: String, CodingKey {
        case level, theme, objective
        case knownLemmas = "known_lemmas", newLemmas = "new_lemmas", targetWords = "target_words"
    }
}

protocol AbsorptionService: Sendable {
    func generate(_ request: AbsorptionRequest) async throws -> AbsorptionText
    /// Un m4a par phrase, dans l'ordre.
    func speak(_ sentences: [String]) async throws -> [Data]
}

struct AbsorptionClient: AbsorptionService {
    let baseURL: URL
    var session: URLSession = .shared

    /// L'IA écrit, mesure, réécrit au besoin, puis le juge repère l'objectif : une
    /// trentaine de secondes, davantage avec deux réécritures.
    static let textTimeout: TimeInterval = 180
    /// XTTS dit une phrase en une à deux secondes : un paquet de 5, une dizaine.
    static let voiceTimeout: TimeInterval = 120

    private struct Speech: Decodable {
        struct Audio: Decodable { let text: String; let audio: String }
        let audios: [Audio]
    }

    func generate(_ request: AbsorptionRequest) async throws -> AbsorptionText {
        let body = try JSONEncoder().encode(request)
        let text = try await HomeServer.post("session/generate-input", base: baseURL, body: body,
                                             contentType: "application/json", timeout: Self.textTimeout,
                                             session: session, as: AbsorptionText.self)
        guard !text.sentences.isEmpty else { throw ServerError.server("Le texte du jour est vide") }
        return text
    }

    func speak(_ sentences: [String]) async throws -> [Data] {
        let body = try JSONEncoder().encode(["sentences": sentences])
        let speech = try await HomeServer.post("tts", base: baseURL, body: body, contentType: "application/json",
                                               timeout: Self.voiceTimeout, session: session, as: Speech.self)
        let audios = speech.audios.compactMap { Data(base64Encoded: $0.audio) }
        guard audios.count == sentences.count else { throw ServerError.server("Voix incomplète") }
        return audios
    }
}

#if DEBUG
/// Le texte imaginaire des tests d'interface : trois phrases, la deuxième sur l'objectif.
struct FakeAbsorptionService: AbsorptionService {
    func generate(_ request: AbsorptionRequest) async throws -> AbsorptionText {
        let first = request.newLemmas.first ?? "mochila"
        return AbsorptionText(
            text: "", sentences: [.init(es: "Hoy llevo la \(first) al parque.", fr: "Aujourd'hui j'emporte le mot au parc."),
                                  .init(es: "Ayer hacía sol cuando llegué.", fr: "Hier il faisait beau quand je suis arrivé."),
                                  .init(es: "Mañana volveré.", fr: "Demain je reviendrai.")],
            coverage: 1, unknownLemmas: [], newUsed: [first], objectiveHits: [1], attempts: 1,
            newOccurrences: [.init(lemma: first, sentence: 0, form: first)])
    }

    func speak(_ sentences: [String]) async throws -> [Data] { sentences.map { _ in Data() } }
}
#endif

// MARK: - Les audios

/// La voix du texte du jour, un fichier par phrase : `absorption/<séance>/03.m4a`, dans
/// Application Support. Seule la séance en cours garde les siens : le texte reste en
/// base, la voix peut toujours se refaire.
enum AbsorptionAudio {
    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "absorption", directoryHint: .isDirectory)
    }

    static func folder(for sessionKey: String, root: URL = defaultRoot) -> URL {
        // « es:2026-11-18#2 » : ni deux-points ni dièse dans un nom de dossier.
        root.appending(path: sessionKey.replacingOccurrences(of: ":", with: "-")
                           .replacingOccurrences(of: "#", with: "-"), directoryHint: .isDirectory)
    }

    static func url(sessionKey: String, sentence: Int, root: URL = defaultRoot) -> URL {
        folder(for: sessionKey, root: root).appending(path: String(format: "%02d.m4a", sentence))
    }

    static func exists(sessionKey: String, sentence: Int, root: URL = defaultRoot) -> Bool {
        FileManager.default.fileExists(atPath: url(sessionKey: sessionKey, sentence: sentence, root: root).path)
    }

    /// Les phrases dont la voix manque.
    static func missing(sessionKey: String, count: Int, root: URL = defaultRoot) -> [Int] {
        (0..<count).filter { !exists(sessionKey: sessionKey, sentence: $0, root: root) }
    }

    static func write(_ data: Data, sessionKey: String, sentence: Int, root: URL = defaultRoot) throws {
        let folder = folder(for: sessionKey, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url(sessionKey: sessionKey, sentence: sentence, root: root), options: .atomic)
    }

    /// Supprime la voix des autres séances.
    static func purge(keeping sessionKey: String, root: URL = defaultRoot) {
        let keep = folder(for: sessionKey, root: root).standardizedFileURL.lastPathComponent
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

// MARK: - La séance

@MainActor
enum Absorption {
    /// Le texte visé : 80 à 110 mots, pour un cycle d'un quart d'heure (étape 5a).
    static let targetWords = 95
    /// Les phrases envoyées à la voix en une demande : la progression se voit, et un
    /// paquet raté ne fait pas tout refaire.
    static let voiceBatch = 5
    /// La partie qui dit que les mots du texte ont été vus (une fois par séance).
    static let seenPart = "\(StudyBlock.absorption.rawValue).seen"

    static func text(of session: StudySession) -> AbsorptionText? {
        session.inputData.flatMap { try? JSONDecoder().decode(AbsorptionText.self, from: $0) }
    }

    static func store(_ text: AbsorptionText, in session: StudySession) {
        session.inputData = try? JSONEncoder().encode(text)
        session.updatedAt = .now
    }

    /// Ce que la route attend pour cette séance, ou la raison qui l'empêche.
    static func request(for session: StudySession, pack: CurriculumPack,
                        in context: ModelContext) -> Result<AbsorptionRequest, AbsorptionFailure> {
        guard let objective = session.objectiveID.flatMap(pack.objective) else {
            return .failure(.init("Pas d'objectif aujourd'hui : pas de texte à écrire."))
        }
        guard let theme = pack.themes.first(where: { $0.id == session.theme }) ?? pack.themes.first else {
            return .failure(.init("Aucun thème dans le paquet."))
        }
        let estimate = PlacementStore.latestCompleted(language: pack.language, in: context)?.lexiconEstimate ?? 0
        let states = (try? context.fetch(FetchDescriptor<LexemeState>())) ?? []
        // Le niveau de l'apprenant, pas celui d'un objectif repris (étape 5b).
        return .success(AbsorptionRequest(
            level: LearnerLevel.current(pack: pack, in: context) ?? objective.level, theme: theme.es, objective: ConversationObjective(objective),
            knownLemmas: KnownVocabulary.lemmas(pack: pack, estimate: estimate, states: states),
            newLemmas: session.newLemmas, targetWords: targetWords))
    }

    /// Les mots nouveaux employés dans le texte passent « vus », une fois par séance.
    /// Chacun garde la phrase où il apparaît : c'est le recto de sa carte. Un mot de la
    /// liste que l'IA n'a pas employé reste inconnu : il sera reproposé.
    static func markSeen(_ text: AbsorptionText, in session: StudySession, ranks: [String: Int],
                         at date: Date, in context: ModelContext) {
        guard session.blocks.parts[seenPart] == nil else { return }
        let language = session.language
        let existing = Dictionary(
            ((try? context.fetch(FetchDescriptor<LexemeState>())) ?? [])
                .filter { $0.language == language }.map { ($0.lemma, $0) },
            uniquingKeysWith: { first, _ in first })
        let occurrences = Dictionary(text.occurrences.map { ($0.lemma, $0) }, uniquingKeysWith: { first, _ in first })
        for lemma in text.newUsed where !lemma.isEmpty {
            let state = existing[lemma] ?? {
                let created = LexemeState(language: language, lemma: lemma, rank: ranks[lemma],
                                          source: LexiconWords.source, at: date)
                context.insert(created)
                return created
            }()
            if let occurrence = occurrences[lemma] {
                let sentence = text.sentences[occurrence.sentence]
                state.recordSeen(sentence: sentence.es, form: occurrence.form, translation: sentence.fr)
            } else {
                state.seenCount += 1
            }
        }
        StudySessionProgress.markPart(seenPart, in: session, at: date)
    }
}

struct AbsorptionFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Prépare le texte du jour et sa voix, en tâche de fond : lancée dès l'écran de la
/// séance, la préparation continue pendant le bloc 1, d'un écran à l'autre. Une seule à
/// la fois par séance.
@Observable
@MainActor
final class AbsorptionPreparer {
    enum Phase: Equatable {
        case idle
        case writing
        case speaking(done: Int, total: Int)
        case ready
        /// Le texte n'a pas pu être écrit.
        case failed(String)
        /// Le texte est là, sa voix non.
        case voiceFailed(String)
    }

    private(set) var phases: [String: Phase] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let root: URL

    init(root: URL = AbsorptionAudio.defaultRoot) {
        self.root = root
    }

    func phase(for session: StudySession) -> Phase {
        if let phase = phases[session.key] { return phase }
        guard let text = Absorption.text(of: session) else { return .idle }
        return AbsorptionAudio.missing(sessionKey: session.key, count: text.sentences.count, root: root).isEmpty
            ? .ready : .idle
    }

    func audioURL(for session: StudySession, sentence: Int) -> URL? {
        AbsorptionAudio.exists(sessionKey: session.key, sentence: sentence, root: root)
            ? AbsorptionAudio.url(sessionKey: session.key, sentence: sentence, root: root) : nil
    }

    var isRunning: Bool { !tasks.isEmpty }

    /// Écrit le texte s'il manque, puis la voix des phrases qui n'en ont pas. Sans effet
    /// si c'est déjà fait ou en cours.
    func prepare(_ session: StudySession, pack: CurriculumPack, service: any AbsorptionService,
                 in context: ModelContext) {
        let key = session.key
        guard tasks[key] == nil, phase(for: session) != .ready else { return }
        AbsorptionAudio.purge(keeping: key, root: root)
        tasks[key] = Task { [weak self] in
            await self?.run(session, key: key, pack: pack, service: service, context: context)
            self?.tasks[key] = nil
        }
    }

    private func run(_ session: StudySession, key: String, pack: CurriculumPack,
                     service: any AbsorptionService, context: ModelContext) async {
        var text = Absorption.text(of: session)
        if text == nil {
            switch Absorption.request(for: session, pack: pack, in: context) {
            case .failure(let failure):
                phases[key] = .failed(failure.message)
                return
            case .success(let request):
                phases[key] = .writing
                do {
                    let written = try await service.generate(request)
                    Absorption.store(written, in: session)
                    try? context.save()
                    text = written
                } catch {
                    phases[key] = .failed(error.localizedDescription)
                    return
                }
            }
        }
        guard let text else { return }
        let missing = AbsorptionAudio.missing(sessionKey: key, count: text.sentences.count, root: root)
        let total = text.sentences.count
        var done = total - missing.count
        for start in stride(from: 0, to: missing.count, by: Absorption.voiceBatch) {
            phases[key] = .speaking(done: done, total: total)
            let batch = Array(missing[start..<min(start + Absorption.voiceBatch, missing.count)])
            do {
                let audios = try await service.speak(batch.map { text.sentences[$0].es })
                for (index, audio) in zip(batch, audios) {
                    try AbsorptionAudio.write(audio, sessionKey: key, sentence: index, root: root)
                }
                done += batch.count
            } catch {
                phases[key] = .voiceFailed(error.localizedDescription)
                return
            }
        }
        phases[key] = .ready
    }
}
