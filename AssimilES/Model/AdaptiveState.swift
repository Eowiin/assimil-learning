import Foundation
import SwiftData

// L'état de l'apprenant pour le moteur adaptatif : objectifs, lexique, placement,
// séance du jour, écrits. Le contenu reste dans `CurriculumPack` ; ces tables le
// désignent par des clés préfixées par la langue (« es:obj_014 », « es:hablar »).
//
// Six entités ajoutées, aucune existante modifiée : une migration légère, que la
// sauvegarde (copie du fichier SQLite) emporte d'office. Tous les champs ont une
// valeur par défaut, comme ailleurs.

enum AdaptiveKey {
    static func make(language: String, _ id: String) -> String { "\(language):\(id)" }
}

// MARK: - Objectifs

/// Où en est un micro-objectif. Le journal (`ObjectiveEvidence`) est la source de
/// vérité ; ces compteurs n'en sont qu'un cache.
@Model
final class ObjectiveProgress {
    #Unique<ObjectiveProgress>([\.key])
    #Index<ObjectiveProgress>([\.status])

    /// « es:obj_014 ».
    var key: String = ""
    var language: String = "es"
    var objectiveID: String = ""
    var status: String = ObjectiveProgress.Status.locked
    /// Les productions spontanées réussies (conversation, écrit), pas les défis.
    var successes: Int = 0
    var activatedAt: Date?
    var lastEvidenceAt: Date?
    var acquiredAt: Date?
    var updatedAt: Date = Date.now

    init(language: String, objectiveID: String, status: String = Status.locked, at date: Date) {
        self.key = AdaptiveKey.make(language: language, objectiveID)
        self.language = language
        self.objectiveID = objectiveID
        self.status = status
        self.updatedAt = date
        if status == Status.active { activatedAt = date }
    }

    enum Status {
        /// Pas encore abordé.
        static let locked = "locked"
        /// L'objectif du moment : la séance le travaille.
        static let active = "active"
        /// Trois productions spontanées réussies.
        static let acquired = "acquired"
        /// Laissé de côté sans être acquis (lacune du placement, ou déblocage souple
        /// après deux jours) : à remettre dans les séances suivantes.
        static let toReinject = "to_reinject"
    }

    /// Le seuil du plan : validé après trois productions spontanées réussies.
    static let successesToAcquire = 3
    /// Le déblocage souple : après deux jours actif sans être acquis.
    static let softUnlockAfter: TimeInterval = 2 * 24 * 3600

    var isAcquired: Bool { status == Status.acquired }

    /// Un objectif actif depuis assez longtemps pour passer au suivant, sans l'acquérir.
    func isDueForSoftUnlock(now: Date) -> Bool {
        guard status == Status.active, let activatedAt else { return false }
        return now.timeIntervalSince(activatedAt) >= Self.softUnlockAfter
    }
}

/// Une preuve d'emploi d'un objectif, ajoutée et jamais modifiée.
@Model
final class ObjectiveEvidence {
    #Index<ObjectiveEvidence>([\.objectiveKey], [\.at])

    var objectiveKey: String = ""
    var at: Date = Date.now
    var source: String = ObjectiveEvidence.Source.conversation
    var valid: Bool = false
    /// La phrase de l'apprenant, telle qu'entendue ou écrite.
    var said: String?
    /// Le commentaire court du correcteur (`analyse_courte`).
    var analysis: String?

    init(objectiveKey: String, at: Date, source: String, valid: Bool, said: String? = nil, analysis: String? = nil) {
        self.objectiveKey = objectiveKey
        self.at = at
        self.source = source
        self.valid = valid
        self.said = said
        self.analysis = analysis
    }

    enum Source {
        static let conversation = "conversation"
        static let writing = "writing"
        /// Un défi du placement : il situe, il ne compte pas comme production spontanée.
        static let placement = "placement"
    }

    var isSpontaneous: Bool { source != Source.placement }
}

@MainActor
enum ObjectiveTracker {
    /// La ligne d'un objectif, créée verrouillée si elle n'existe pas.
    static func progress(language: String, objectiveID: String, at date: Date,
                         in context: ModelContext) throws -> ObjectiveProgress {
        let key = AdaptiveKey.make(language: language, objectiveID)
        if let existing = try context.fetch(FetchDescriptor<ObjectiveProgress>(predicate: #Predicate { $0.key == key })).first {
            return existing
        }
        let progress = ObjectiveProgress(language: language, objectiveID: objectiveID, at: date)
        context.insert(progress)
        return progress
    }

    /// Inscrit une preuve et met le cache à jour. Une production spontanée réussie
    /// compte ; à la troisième, l'objectif est acquis (même s'il avait été laissé de
    /// côté : il revient en emploi, et c'est ce qu'on attendait de lui).
    static func record(_ evidence: ObjectiveEvidence, on progress: ObjectiveProgress, in context: ModelContext) {
        context.insert(evidence)
        progress.lastEvidenceAt = max(progress.lastEvidenceAt ?? .distantPast, evidence.at)
        progress.updatedAt = evidence.at
        guard evidence.valid, evidence.isSpontaneous, !progress.isAcquired else { return }
        progress.successes += 1
        if progress.successes >= ObjectiveProgress.successesToAcquire {
            progress.status = ObjectiveProgress.Status.acquired
            progress.acquiredAt = evidence.at
        }
    }

    static func activate(_ progress: ObjectiveProgress, at date: Date) {
        guard !progress.isAcquired else { return }
        progress.status = ObjectiveProgress.Status.active
        progress.activatedAt = date
        progress.updatedAt = date
    }

    /// Le déblocage souple : l'objectif passe « à réinjecter », le suivant peut venir.
    @discardableResult
    static func softUnlockIfDue(_ progress: ObjectiveProgress, now: Date) -> Bool {
        guard progress.isDueForSoftUnlock(now: now) else { return false }
        progress.status = ObjectiveProgress.Status.toReinject
        progress.updatedAt = now
        return true
    }
}

// MARK: - Lexique

/// Ce que l'apprenant sait d'un lemme : vu, reconnu, actif. Le statut ne fait que
/// monter ; les dates disent quand.
@Model
final class LexemeState {
    #Unique<LexemeState>([\.key])
    #Index<LexemeState>([\.status], [\.rank])

    /// « es:hablar ».
    var key: String = ""
    var language: String = "es"
    var lemma: String = ""
    /// Le rang dans `lexicon.json`, nil hors des 5 000 (une expression, un mot rare).
    var rank: Int?
    var status: String = LexemeState.Status.seen
    var seenCount: Int = 0
    /// Les productions de l'apprenant (conversation, écrit), et le dernier jour.
    var productions: Int = 0
    var productionDays: Int = 0
    var lastProducedAt: Date?
    var firstSeenAt: Date = Date.now
    var recognizedAt: Date?
    var activeAt: Date?
    /// D'où vient la connaissance : « assimil », « placement », « input »…
    var source: String = ""

    init(language: String, lemma: String, rank: Int?, source: String, at date: Date) {
        self.key = AdaptiveKey.make(language: language, lemma)
        self.language = language
        self.lemma = lemma
        self.rank = rank
        self.source = source
        self.firstSeenAt = date
    }

    enum Status {
        static let seen = "seen"
        static let recognized = "recognized"
        static let active = "active"

        static func order(_ status: String) -> Int {
            switch status {
            case active: 2
            case recognized: 1
            default: 0
            }
        }
    }

    /// Les jours de production distincts qu'il faut pour qu'un mot devienne actif.
    static let productionDaysToActivate = 2

    /// Un mot dit ou écrit par l'apprenant : il le reconnaît, et le deuxième jour où il
    /// le produit, il le possède.
    func recordProduction(at date: Date, calendar: Calendar = .current) {
        if lastProducedAt.map({ !calendar.isDate($0, inSameDayAs: date) }) ?? true { productionDays += 1 }
        productions += 1
        lastProducedAt = date
        raise(to: productionDays >= Self.productionDaysToActivate ? Status.active : Status.recognized, at: date)
    }

    /// Monte le statut, jamais ne le descend. Rend vrai s'il a changé.
    @discardableResult
    func raise(to newStatus: String, at date: Date) -> Bool {
        guard Status.order(newStatus) > Status.order(status) else { return false }
        if Status.order(newStatus) >= Status.order(Status.recognized), recognizedAt == nil { recognizedAt = date }
        if newStatus == Status.active, activeAt == nil { activeAt = date }
        status = newStatus
        return true
    }
}

// MARK: - Placement

/// Un passage du test de positionnement. Le détail (réponses du test de vocabulaire,
/// défis et verdicts, sons) est gardé en JSON : il se relit en entier ou pas du tout.
@Model
final class PlacementResult {
    #Index<PlacementResult>([\.takenAt])

    var takenAt: Date = Date.now
    var language: String = "es"
    /// L'estimation du vocabulaire passif, en lemmes.
    var lexiconEstimate: Int = 0
    var level: String = "A1"
    /// L'objectif de départ, sans préfixe de langue (« obj_026 »).
    var startObjectiveID: String?
    var details: Data = Data()
    /// Nil tant que le passage n'est pas validé : les parties faites sont gardées, et
    /// le test reprend où il s'était arrêté. Ajouté à l'étape 3, optionnel : migration
    /// légère.
    var completedAt: Date?

    init(takenAt: Date, language: String, lexiconEstimate: Int, level: String, startObjectiveID: String?) {
        self.takenAt = takenAt
        self.language = language
        self.lexiconEstimate = lexiconEstimate
        self.level = level
        self.startObjectiveID = startObjectiveID
    }

    var isCompleted: Bool { completedAt != nil }

    var placementDetails: PlacementDetails {
        get { (try? JSONDecoder().decode(PlacementDetails.self, from: details)) ?? PlacementDetails() }
        set { details = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

/// Le détail d'un passage : chaque partie, telle qu'elle s'est passée. Une partie
/// absente n'a pas encore été faite.
struct PlacementDetails: Codable, Equatable {
    var vocabulary: VocabularyTest.Outcome?
    /// Les défis jugés, dans l'ordre où ils ont été posés.
    var challenges: [ChallengeRecord] = []
    /// La conversation de calibrage, faite ou passée.
    var calibration: CalibrationOutcome?
    /// Le diagnostic des sons, fait ou passé.
    var sounds: SoundsOutcome?

    init(vocabulary: VocabularyTest.Outcome? = nil, challenges: [ChallengeRecord] = [],
         calibration: CalibrationOutcome? = nil, sounds: SoundsOutcome? = nil) {
        self.vocabulary = vocabulary
        self.challenges = challenges
        self.calibration = calibration
        self.sounds = sounds
    }

    /// Un passage commencé avant les défis (étape 3a) n'a pas de clé `challenges`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vocabulary = try c.decodeIfPresent(VocabularyTest.Outcome.self, forKey: .vocabulary)
        challenges = try c.decodeIfPresent([ChallengeRecord].self, forKey: .challenges) ?? []
        calibration = try c.decodeIfPresent(CalibrationOutcome.self, forKey: .calibration)
        sounds = try c.decodeIfPresent(SoundsOutcome.self, forKey: .sounds)
    }
}

@MainActor
enum PlacementStore {
    /// Le passage en cours, s'il y en a un : le plus récent qui n'est pas validé.
    static func draft(language: String = "es", in context: ModelContext) -> PlacementResult? {
        drafts(language: language, in: context).first
    }

    /// Le dernier passage validé.
    static func latestCompleted(language: String = "es", in context: ModelContext) -> PlacementResult? {
        let all = (try? context.fetch(FetchDescriptor<PlacementResult>(
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]))) ?? []
        return all.first { $0.language == language && $0.isCompleted }
    }

    /// Le test de vocabulaire fini ouvre un nouveau passage, et remplace celui qui
    /// traînait : on ne reprend pas les défis d'un autre test de vocabulaire. Les
    /// passages validés restent.
    @discardableResult
    static func startWithVocabulary(_ outcome: VocabularyTest.Outcome, language: String = "es",
                                    at date: Date, in context: ModelContext) -> PlacementResult {
        for old in drafts(language: language, in: context) { context.delete(old) }
        let result = PlacementResult(takenAt: date, language: language, lexiconEstimate: outcome.estimate,
                                     level: outcome.level, startObjectiveID: nil)
        result.placementDetails = PlacementDetails(vocabulary: outcome)
        context.insert(result)
        try? context.save()
        return result
    }

    private static func drafts(language: String, in context: ModelContext) -> [PlacementResult] {
        let all = (try? context.fetch(FetchDescriptor<PlacementResult>(
            predicate: #Predicate { $0.completedAt == nil },
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]))) ?? []
        return all.filter { $0.language == language }
    }
}

// MARK: - Séance du jour

/// Les quatre blocs de la séance adaptative, dans l'ordre.
enum StudyBlock: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable {
    /// Révisions, micro-leçon, shadowing des sons faibles.
    case surgery
    /// Le texte du jour, calibré sur les mots connus.
    case absorption
    /// Le jeu de rôle qui provoque l'objectif.
    case conversation
    /// L'oral rapide sur des mots actifs, puis l'écrit.
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .surgery: "Chirurgie"
        case .absorption: "Absorption"
        case .conversation: "Conversation"
        case .automation: "Automatisation"
        }
    }

    /// La durée prévue, en minutes.
    var minutes: Int { 15 }
}

/// Où en est chaque bloc. Rangé en JSON dans `StudySession`, comme `DailyProgress`.
struct StudyBlockProgress: Codable, Equatable {
    var completed: [StudyBlock: Date] = [:]
    /// Passé sans être fait : on ne peut pas parler à voix haute, le PC est éteint…
    var skipped: [StudyBlock: Date] = [:]
    var seconds: [StudyBlock: Double] = [:]
    /// Les parties d'un bloc déjà faites (« surgery.microlesson »), pour les cocher.
    var parts: [String: Date] = [:]

    init() {}

    /// `skipped` est venu à l'étape 4a.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completed = try c.decodeIfPresent([StudyBlock: Date].self, forKey: .completed) ?? [:]
        skipped = try c.decodeIfPresent([StudyBlock: Date].self, forKey: .skipped) ?? [:]
        seconds = try c.decodeIfPresent([StudyBlock: Double].self, forKey: .seconds) ?? [:]
        parts = try c.decodeIfPresent([String: Date].self, forKey: .parts) ?? [:]
    }

    func isSettled(_ block: StudyBlock) -> Bool { completed[block] != nil || skipped[block] != nil }
    /// Le prochain bloc ni fait ni passé, dans l'ordre fixe.
    var next: StudyBlock? { StudyBlock.allCases.first { !isSettled($0) } }
    var isDone: Bool { next == nil }
    var totalSeconds: Double { seconds.values.reduce(0, +) }

    /// Fait : il ne l'est plus de passé.
    mutating func complete(_ block: StudyBlock, at date: Date) {
        completed[block] = date
        skipped[block] = nil
    }

    mutating func skip(_ block: StudyBlock, at date: Date) {
        guard completed[block] == nil else { return }
        skipped[block] = date
    }

    mutating func add(_ seconds: Double, to block: StudyBlock) {
        guard seconds > 0 else { return }
        self.seconds[block, default: 0] += seconds
    }
}

/// La séance adaptative d'un jour, une par jour et par langue. Le texte du bloc 2 y est
/// gardé tel que le serveur l'a rendu : il se relit sans le PC.
@Model
final class StudySession {
    #Unique<StudySession>([\.key])
    #Index<StudySession>([\.day])

    /// « es:2026-11-17 ».
    var key: String = ""
    var language: String = "es"
    var day: Date = Date.now
    var objectiveID: String?
    /// L'identifiant du thème du bloc 2 (« th_04 », `themes.json`).
    var theme: String?
    /// Les mots nouveaux du jour, apportés par le texte du bloc 2. Ajouté à l'étape 4a.
    var newLemmas: [String] = []
    /// Un objectif laissé de côté, que la consigne de l'écrit du bloc 4 rappelle.
    var reinjectObjectiveID: String?
    var blocksData: Data = Data()
    /// La réponse de `/session/generate-input`, en JSON. Nil avant la génération.
    var inputData: Data?
    var startedAt: Date = Date.now
    var updatedAt: Date = Date.now
    var completedAt: Date?

    init(language: String, day: Date, objectiveID: String?, startedAt: Date, calendar: Calendar = .current) {
        self.language = language
        self.day = calendar.startOfDay(for: day)
        self.key = Self.makeKey(language: language, day: day, calendar: calendar)
        self.objectiveID = objectiveID
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.blocksData = (try? JSONEncoder().encode(StudyBlockProgress())) ?? Data()
    }

    var blocks: StudyBlockProgress {
        get { (try? JSONDecoder().decode(StudyBlockProgress.self, from: blocksData)) ?? StudyBlockProgress() }
        set {
            guard let data = try? JSONEncoder().encode(newValue), data != blocksData else { return }
            blocksData = data
            updatedAt = .now
        }
    }

    static func makeKey(language: String, day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%@:%04d-%02d-%02d", language, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Écrit

/// Un texte écrit au bloc 4, et sa correction. Comme `ConversationRecord`, la
/// correction est gardée dans la forme où elle arrive du serveur.
@Model
final class WritingRecord {
    #Index<WritingRecord>([\.writtenAt])

    var writtenAt: Date = Date.now
    var language: String = "es"
    var objectiveID: String?
    /// La consigne donnée.
    var prompt: String?
    var text: String = ""
    /// La réponse de `/writing/review`, en JSON. Nil tant qu'elle n'est pas faite.
    var review: Data?

    init(writtenAt: Date, language: String, objectiveID: String?, prompt: String?, text: String) {
        self.writtenAt = writtenAt
        self.language = language
        self.objectiveID = objectiveID
        self.prompt = prompt
        self.text = text
    }

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

// MARK: - Vocabulaire connu

@MainActor
enum KnownVocabulary {
    /// Les lemmes que l'apprenant connaît : ceux sous la frontière du placement
    /// (`lexiconEstimate`, en rang), plus ceux que l'état dit reconnus ou actifs. C'est
    /// ce que mesure le serveur (`allowed_lemmas`, `known_lemmas`).
    static func lemmas(pack: CurriculumPack, estimate: Int, states: [LexemeState]) -> [String] {
        var seen = Set<String>()
        let frontier = pack.lexicon.prefix(max(0, estimate)).map(\.lemma)
        let known = states.filter { $0.language == pack.language && $0.status != LexemeState.Status.seen }.map(\.lemma)
        return (frontier + known).filter { seen.insert($0).inserted }
    }

    /// Les lemmes produits en conversation ou à l'écrit, inscrits dans l'état.
    static func recordProduction(_ lemmas: [String], language: String, ranks: [String: Int], source: String,
                                 at date: Date, in context: ModelContext) throws {
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<LexemeState>()).filter { $0.language == language }.map { ($0.lemma, $0) },
            uniquingKeysWith: { first, _ in first })
        for lemma in Set(lemmas) where !lemma.isEmpty {
            let state = existing[lemma] ?? {
                let created = LexemeState(language: language, lemma: lemma, rank: ranks[lemma], source: source, at: date)
                context.insert(created)
                return created
            }()
            state.recordProduction(at: date)
        }
    }
}
