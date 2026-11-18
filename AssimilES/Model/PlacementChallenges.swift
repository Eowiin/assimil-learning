import Foundation
import Observation
import SwiftData

// Les défis du placement (`docs/moteur-adaptatif.md`, étape 3b) : posés niveau par
// niveau, jugés par le serveur (`POST /placement/evaluate`), puis l'état de l'apprenant
// écrit à la validation.

typealias PlacementChallenge = CurriculumPack.PlacementChallenge
typealias ChallengeVerdict = CurriculumPack.PlacementChallenge.Verdict

/// Un défi répondu et jugé, gardé dans le détail du passage.
struct ChallengeRecord: Codable, Equatable, Sendable {
    let challengeID: String
    let objectiveID: String
    let level: String
    let answer: String
    let verdict: ChallengeVerdict
    /// L'`analyse_courte` du juge.
    let analysis: String
}

// MARK: - Le serveur

/// Un défi tel que la route le reçoit : le défi du paquet, et la réponse.
struct PlacementItem: Encodable, Equatable, Sendable {
    let objectiveID: String
    let instruction: String
    let prompt: String
    let expected: [String]
    let alsoCorrect: [String]
    let check: String
    let answer: String

    init(_ challenge: PlacementChallenge, answer: String) {
        objectiveID = challenge.objective
        instruction = challenge.instruction
        prompt = challenge.prompt
        expected = challenge.expected
        alsoCorrect = challenge.alsoCorrect
        check = challenge.check
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case objectiveID = "objective_id", instruction, prompt, expected, alsoCorrect = "also_correct", check, answer
    }
}

/// Un verdict de la route.
struct PlacementJudgement: Decodable, Equatable, Sendable {
    let objectiveID: String
    let verdict: ChallengeVerdict
    let analysis: String

    private enum CodingKeys: String, CodingKey {
        case objectiveID = "objective_id", verdict, analysis = "analyse_courte"
    }
}

protocol PlacementService: Sendable {
    /// Un verdict par défi, dans l'ordre des défis.
    func evaluate(level: String, items: [PlacementItem]) async throws -> [PlacementJudgement]
}

struct PlacementClient: PlacementService {
    let baseURL: URL
    var session: URLSession = .shared

    /// Un paquet de défis va au juge en une fois : quelques secondes, davantage si un
    /// défi oublié est rejugé seul.
    static let timeout: TimeInterval = 90

    private struct Body: Encodable {
        let level: String
        let items: [PlacementItem]
    }

    func evaluate(level: String, items: [PlacementItem]) async throws -> [PlacementJudgement] {
        let body = try JSONEncoder().encode(Body(level: level, items: items))
        let judgements = try await HomeServer.post("placement/evaluate", base: baseURL, body: body,
                                                   contentType: "application/json", timeout: Self.timeout,
                                                   session: session, as: [PlacementJudgement].self)
        // La route rend un verdict par défi, dans l'ordre : sinon, rien n'est sûr.
        guard judgements.map(\.objectiveID) == items.map(\.objectiveID) else {
            throw ServerError.server("Verdicts du placement incomplets")
        }
        return judgements
    }
}

#if DEBUG
/// Le juge imaginaire des tests d'interface : « faux » est faux, « autre » contourne
/// l'objectif, le reste le montre. Une réponse vide est fausse, comme au serveur.
struct FakePlacementService: PlacementService {
    func evaluate(level: String, items: [PlacementItem]) async throws -> [PlacementJudgement] {
        items.map { item in
            let answer = item.answer.lowercased()
            let verdict: ChallengeVerdict = answer.trimmingCharacters(in: .whitespaces).isEmpty || answer.contains("faux")
                ? .wrong : answer.contains("autre") ? .correctNotShown : .shown
            return PlacementJudgement(objectiveID: item.objectiveID, verdict: verdict, analysis: "Jugement de test.")
        }
    }
}
#endif

// MARK: - La montée par niveau

/// Quels défis poser, et quand s'arrêter. Tout se déduit des défis déjà jugés : un
/// passage interrompu reprend où il en était.
///
/// 4 défis par niveau (3 en A0, qui n'en a pas plus). Un niveau est réussi quand les
/// trois quarts des défis tranchés montrent l'objectif. Un défi juste qui contourne
/// l'objectif ne tranche rien : on pose celui d'un autre objectif du même niveau, deux
/// fois au plus. On commence au niveau du vocabulaire ; on monte tant que ça passe ; si
/// le premier niveau échoue, on descend jusqu'à un niveau réussi.
enum ChallengeWalk {

    static let perLevel = 4
    static let replacementsPerLevel = 2
    static let passRate = 0.75

    enum Step: Equatable {
        case ask(level: String, challenges: [PlacementChallenge])
        /// Le niveau de travail : le premier qui n'est pas réussi (le plus haut, si tout l'est).
        case done(workingLevel: String)
    }

    struct LevelOutcome: Equatable {
        let level: String
        let shown: Int
        let wrong: Int
        let notShown: Int

        var passed: Bool {
            let decided = shown + wrong
            return decided > 0 && Double(shown) / Double(decided) >= ChallengeWalk.passRate
        }
    }

    /// Les niveaux qui ont des défis, dans l'ordre du CECRL.
    static func levels(of challenges: [PlacementChallenge]) -> [String] {
        CurriculumPack.levels.filter { level in challenges.contains { $0.level == level } }
    }

    /// Le niveau de départ : celui du vocabulaire, ou le plus proche en dessous.
    static func startLevel(vocabulary: String, challenges: [PlacementChallenge]) -> String {
        let levels = levels(of: challenges)
        let rank = CurriculumPack.levels.firstIndex(of: vocabulary) ?? 0
        return levels.last { (CurriculumPack.levels.firstIndex(of: $0) ?? 0) <= rank } ?? levels.first ?? vocabulary
    }

    /// Les niveaux passés, dans l'ordre où ils l'ont été.
    static func outcomes(_ records: [ChallengeRecord]) -> [LevelOutcome] {
        var order: [String] = []
        for record in records where !order.contains(record.level) { order.append(record.level) }
        return order.map { level in
            let at = records.filter { $0.level == level }
            return LevelOutcome(level: level,
                                shown: at.filter { $0.verdict == .shown }.count,
                                wrong: at.filter { $0.verdict == .wrong }.count,
                                notShown: at.filter { $0.verdict == .correctNotShown }.count)
        }
    }

    static func next<G: RandomNumberGenerator>(records: [ChallengeRecord], start: String,
                                               challenges: [PlacementChallenge],
                                               using generator: inout G) -> Step {
        let levels = levels(of: challenges)
        func draw(_ level: String, _ count: Int) -> Step {
            let used = Set(records.map(\.challengeID))
            let unused = challenges.filter { $0.level == level && !used.contains($0.id) }
            return .ask(level: level, challenges: Array(unused.shuffled(using: &generator).prefix(count)))
        }
        func base(_ level: String) -> Int { min(perLevel, challenges.filter { $0.level == level }.count) }

        let outcomes = outcomes(records)
        guard let last = outcomes.last, let index = levels.firstIndex(of: last.level) else {
            return draw(start, base(start))
        }

        // Le niveau en cours n'est pas fini : des défis contournés sont à remplacer.
        let asked = last.shown + last.wrong + last.notShown
        let target = base(last.level) + min(last.notShown, replacementsPerLevel)
        let left = challenges.filter { $0.level == last.level }.count - asked
        if asked < target, left > 0 {
            return draw(last.level, min(target - asked, left))
        }

        if outcomes[0].passed {
            // On monte : le premier échec donne le niveau de travail.
            guard last.passed else { return .done(workingLevel: last.level) }
            guard index + 1 < levels.count else { return .done(workingLevel: last.level) }
            let up = levels[index + 1]
            return draw(up, base(up))
        } else {
            // On descend : le premier niveau réussi place juste au-dessus de lui.
            if last.passed { return .done(workingLevel: levels[index + 1]) }
            guard index > 0 else { return .done(workingLevel: last.level) }
            let down = levels[index - 1]
            return draw(down, base(down))
        }
    }

    static func next(records: [ChallengeRecord], start: String, challenges: [PlacementChallenge]) -> Step {
        var generator = SystemRandomNumberGenerator()
        return next(records: records, start: start, challenges: challenges, using: &generator)
    }
}

// MARK: - Un passage des défis

/// Les défis d'un passage, un à la fois. Les réponses d'un niveau partent ensemble au
/// juge ; chaque paquet jugé est gardé dans le passage avant de passer au suivant.
@Observable
@MainActor
final class ChallengeSession {

    enum Phase: Equatable {
        case answering
        case judging
        case failed(String)
        case finished(workingLevel: String)
    }

    let result: PlacementResult
    private let challenges: [PlacementChallenge]
    private let service: any PlacementService
    private let context: ModelContext
    private let start: String

    private(set) var phase: Phase = .answering
    private(set) var level: String = ""
    private(set) var batch: [PlacementChallenge] = []
    private(set) var answers: [String] = []

    init(result: PlacementResult, pack: CurriculumPack, service: any PlacementService, context: ModelContext) {
        self.result = result
        self.challenges = pack.challenges
        self.service = service
        self.context = context
        self.start = ChallengeWalk.startLevel(vocabulary: result.placementDetails.vocabulary?.level ?? result.level,
                                              challenges: pack.challenges)
        advance()
    }

    var records: [ChallengeRecord] { result.placementDetails.challenges }
    var current: PlacementChallenge? { phase == .answering && answers.count < batch.count ? batch[answers.count] : nil }
    /// Le numéro du défi affiché, depuis le début du passage.
    var number: Int { records.count + answers.count + 1 }

    func submit(_ answer: String) async {
        guard current != nil else { return }
        answers.append(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        if answers.count == batch.count { await judge() }
    }

    func retry() async {
        guard case .failed = phase else { return }
        await judge()
    }

    private func judge() async {
        phase = .judging
        let items = zip(batch, answers).map { PlacementItem($0, answer: $1) }
        do {
            let judgements = try await service.evaluate(level: level, items: items)
            var details = result.placementDetails
            details.challenges += zip(zip(batch, answers), judgements).map { pair, judgement in
                ChallengeRecord(challengeID: pair.0.id, objectiveID: pair.0.objective, level: pair.0.level,
                                answer: pair.1, verdict: judgement.verdict, analysis: judgement.analysis)
            }
            result.placementDetails = details
            try? context.save()
            advance()
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func advance() {
        switch ChallengeWalk.next(records: records, start: start, challenges: challenges) {
        case .ask(let level, let challenges):
            self.level = level
            batch = challenges
            answers = []
            phase = .answering
        case .done(let working):
            batch = []
            answers = []
            phase = .finished(workingLevel: working)
        }
    }
}

// MARK: - La validation

@MainActor
enum PlacementCompletion {

    /// Le passage validé au niveau choisi : les objectifs, le lexique, le passage lui-même.
    ///
    /// - En dessous du niveau de travail : acquis, sauf un défi faux (à réinjecter).
    /// - Au niveau de travail et au-dessus : acquis si un défi l'a montré, verrouillé sinon.
    /// - Le premier objectif non acquis à partir du niveau de travail devient actif.
    /// - Un objectif acquis par trois productions spontanées le reste, quoi qu'il arrive.
    /// - Les mots testés « oui » deviennent reconnus, si le test de vocabulaire est fiable.
    ///   Le reste du vocabulaire est la frontière `lexiconEstimate`, pas des lignes.
    @discardableResult
    static func complete(_ result: PlacementResult, workingLevel: String, pack: CurriculumPack,
                         at date: Date, in context: ModelContext) throws -> String? {
        let language = pack.language
        let details = result.placementDetails
        let working = CurriculumPack.levels.firstIndex(of: workingLevel) ?? 0
        var verdicts: [String: ChallengeVerdict] = [:]
        for record in details.challenges { verdicts[record.objectiveID] = record.verdict }

        var progresses: [String: ObjectiveProgress] = [:]
        for objective in pack.objectives {
            let progress = try ObjectiveTracker.progress(language: language, objectiveID: objective.id,
                                                         at: date, in: context)
            progresses[objective.id] = progress
            if progress.isAcquired && progress.successes >= ObjectiveProgress.successesToAcquire { continue }
            let level = CurriculumPack.levels.firstIndex(of: objective.level) ?? 0
            let status: String = switch verdicts[objective.id] {
            case .shown: ObjectiveProgress.Status.acquired
            case .wrong where level < working: ObjectiveProgress.Status.toReinject
            default: level < working ? ObjectiveProgress.Status.acquired : ObjectiveProgress.Status.locked
            }
            progress.status = status
            progress.updatedAt = date
            progress.activatedAt = nil
            progress.acquiredAt = status == ObjectiveProgress.Status.acquired ? (progress.acquiredAt ?? date) : nil
        }

        let start = pack.objectives.first { objective in
            (CurriculumPack.levels.firstIndex(of: objective.level) ?? 0) >= working
                && progresses[objective.id]?.isAcquired == false
        }
        if let start, let progress = progresses[start.id] { ObjectiveTracker.activate(progress, at: date) }

        for record in details.challenges {
            guard let progress = progresses[record.objectiveID] else { continue }
            ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: progress.key, at: date,
                                                      source: ObjectiveEvidence.Source.placement,
                                                      valid: record.verdict == .shown,
                                                      said: record.answer, analysis: record.analysis),
                                    on: progress, in: context)
        }

        if let vocabulary = details.vocabulary, vocabulary.isReliable {
            try recognize(vocabulary.knownWords, language: language, ranks: pack.ranks, at: date, in: context)
        }

        result.level = workingLevel
        result.startObjectiveID = start?.id
        result.completedAt = date
        try context.save()
        return start?.id
    }

    private static func recognize(_ lemmas: [String], language: String, ranks: [String: Int],
                                  at date: Date, in context: ModelContext) throws {
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<LexemeState>()).filter { $0.language == language }.map { ($0.lemma, $0) },
            uniquingKeysWith: { first, _ in first })
        for lemma in Set(lemmas) {
            let state = existing[lemma] ?? {
                let created = LexemeState(language: language, lemma: lemma, rank: ranks[lemma],
                                          source: PlacementCompletion.lexemeSource, at: date)
                context.insert(created)
                return created
            }()
            state.raise(to: LexemeState.Status.recognized, at: date)
        }
    }

    static let lexemeSource = "placement"

    /// L'objectif de départ pour un niveau de travail, avant de rien écrire : l'écran du
    /// résultat le montre quand on change de niveau. Le premier, à partir de ce niveau,
    /// qu'aucun défi n'a montré (`complete` tient compte en plus des objectifs acquis
    /// en conversation).
    static func previewStart(workingLevel: String, records: [ChallengeRecord],
                             pack: CurriculumPack) -> CurriculumPack.Objective? {
        let working = CurriculumPack.levels.firstIndex(of: workingLevel) ?? 0
        let shown = Set(records.filter { $0.verdict == .shown }.map(\.objectiveID))
        return pack.objectives.first {
            (CurriculumPack.levels.firstIndex(of: $0.level) ?? 0) >= working && !shown.contains($0.id)
        }
    }
}
