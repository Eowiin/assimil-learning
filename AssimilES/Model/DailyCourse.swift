import Foundation
import SwiftData

/// Les étapes d'une séance quotidienne, dans l'ordre où elles se font.
enum DailyStage: String, Codable, CaseIterable, Identifiable {
    case discovery
    case comprehension
    case repetition
    case translation
    case completion
    case secondWave
    case finish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discovery: "Découverte"
        case .comprehension: "Compréhension"
        case .repetition: "Répétition"
        case .translation: "Traduction"
        case .completion: "À compléter"
        case .secondWave: "Deuxième vague"
        case .finish: "Fin de séance"
        }
    }

    var symbol: String {
        switch self {
        case .discovery: "headphones"
        case .comprehension: "text.book.closed"
        case .repetition: "repeat"
        case .translation: "character.bubble"
        case .completion: "square.and.pencil"
        case .secondWave: "water.waves"
        case .finish: "checkmark.seal"
        }
    }

    /// Les étapes faites d'éléments à travailler un par un. Elles ne se terminent
    /// que lorsque chaque élément l'est, ou qu'on confirme les avoir faites dans le livre.
    var isExercise: Bool {
        switch self {
        case .translation, .completion, .secondWave: true
        default: false
        }
    }
}

/// Ce que contient la séance d'un jour du parcours.
///
/// Le parcours est une suite de **séances numérotées**, pas de leçons : de la leçon
/// 50 à la 100, chaque séance porte une nouvelle leçon *et* une ancienne en deuxième
/// vague ; au-delà de la 100, la vague continue seule jusqu'à avoir repris toutes
/// les leçons. Numéroter les séances rend cette fin de parcours aussi simple que le
/// reste : la séance 101 est la reprise de la leçon 52.
struct DailyPlan: Hashable {
    let unit: Int
    /// `nil` après la dernière leçon : la séance n'est plus que la deuxième vague.
    let newLesson: Int?
    let waveLesson: Int?
    /// Leçon de révision hebdomadaire (7, 14… 98) — pas les phrases marquées.
    let isWeeklyReview: Bool
    let stages: [DailyStage]

    /// La leçon qui donne son nom à la séance.
    var headlineLesson: Int { newLesson ?? waveLesson ?? unit }
}

enum Curriculum {
    /// Site d'Assimil : la « phase active » commence à la leçon 50, où l'on restitue
    /// les leçons depuis la première. D'où le décalage de 49 : leçon 50 → leçon 1.
    /// Confirmé sur le livre : le bas de la leçon 51 indique « Deuxième vague : 2e leçon ».
    static let waveStartLesson = 50
    static var waveOffset: Int { waveStartLesson - 1 }

    static func lastUnit(in manifest: Manifest = .shared) -> Int {
        manifest.lessonCount + waveOffset
    }

    static func plan(unit: Int, manifest: Manifest = .shared) -> DailyPlan? {
        guard unit >= 1, unit <= lastUnit(in: manifest) else { return nil }
        let newLesson = unit <= manifest.lessonCount ? unit : nil
        let waveLesson = unit >= waveStartLesson ? unit - waveOffset : nil
        let isReview = newLesson.flatMap { manifest.lesson($0)?.isReview } ?? false

        var stages: [DailyStage] = []
        if newLesson != nil {
            stages = [.discovery, .comprehension, .repetition]
            // Les révisions hebdomadaires n'ont pas d'exercices : c'est la
            // structure du livre, pas un contenu manquant.
            if !isReview { stages += [.translation, .completion] }
        }
        if waveLesson != nil { stages.append(.secondWave) }
        stages.append(.finish)

        return DailyPlan(unit: unit, newLesson: newLesson, waveLesson: waveLesson,
                         isWeeklyReview: isReview, stages: stages)
    }
}

enum RevealOutcome: String, Codable {
    case knew
    case notYet
}

/// Une phrase à restituer ou à traduire : on cherche, on répond — de tête ou à voix
/// haute —, on compare.
struct RevealState: Codable, Equatable {
    var revealed = false
    var outcome: RevealOutcome?
    /// Ce que la reconnaissance a entendu, quand la réponse a été dite au micro.
    var heard: String?
    /// La réponse dite était identique à l'attendue (voir `SpokenCheck`).
    var identical: Bool?
}

/// L'avancement d'une séance, sauvegardé à chaque geste.
///
/// Une étape ne se termine **que par un geste explicite** : ni la fin d'une piste,
/// ni un saut à la dernière phrase, ni la sortie du lecteur. C'est ce qui empêche une
/// simple écoute de valider une leçon.
struct DailyProgress: Codable, Equatable {
    var current: DailyStage
    var completed: Set<DailyStage> = []
    /// Phrase où reprendre l'audio, par étape. Une phrase plutôt qu'un index : le
    /// nombre de répétitions peut changer entre deux reprises.
    var audioSentence: [String: Int] = [:]
    var reveals: [String: RevealState] = [:]
    /// Par numéro de phrase de l'exercice 2.
    var fillIns: [String: FillInAttempt] = [:]
    /// Étapes confirmées faites dans le livre, faute de contenu importé.
    var doneInBook: Set<DailyStage> = []

    init(stages: [DailyStage]) {
        current = stages.first ?? .finish
    }

    private enum CodingKeys: String, CodingKey {
        case current, completed, audioSentence, reveals, fillIns, doneInBook
    }

    /// Tolérant : une clé absente ou une étape inconnue ne doit pas perdre le reste.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = (try? c.decode(DailyStage.self, forKey: .current)) ?? .discovery
        completed = Set(((try? c.decode([String].self, forKey: .completed)) ?? []).compactMap(DailyStage.init))
        audioSentence = (try? c.decode([String: Int].self, forKey: .audioSentence)) ?? [:]
        reveals = (try? c.decode([String: RevealState].self, forKey: .reveals)) ?? [:]
        fillIns = (try? c.decode([String: FillInAttempt].self, forKey: .fillIns)) ?? [:]
        doneInBook = Set(((try? c.decode([String].self, forKey: .doneInBook)) ?? []).compactMap(DailyStage.init))
    }

    // MARK: - Étapes

    /// La première étape pas encore terminée : on peut aller jusque-là, pas au-delà.
    func frontier(in stages: [DailyStage]) -> DailyStage {
        stages.first { $0 != .finish && !completed.contains($0) } ?? .finish
    }

    func isReachable(_ stage: DailyStage, in stages: [DailyStage]) -> Bool {
        guard let index = stages.firstIndex(of: stage),
              let limit = stages.firstIndex(of: frontier(in: stages))
        else { return false }
        return index <= limit
    }

    mutating func open(_ stage: DailyStage, in stages: [DailyStage]) {
        guard isReachable(stage, in: stages) else { return }
        current = stage
    }

    /// Termine une étape et ouvre la suivante. Une étape d'exercice refuse tant que
    /// tous ses éléments ne sont pas faits — `items` les désigne.
    @discardableResult
    mutating func complete(_ stage: DailyStage, in stages: [DailyStage], items: [Int] = []) -> Bool {
        guard stage != .finish,
              isReachable(stage, in: stages),
              isDone(stage, items: items)
        else { return false }
        completed.insert(stage)
        if let index = stages.firstIndex(of: stage), index + 1 < stages.count {
            current = stages[index + 1]
        }
        return true
    }

    func isDone(_ stage: DailyStage, items: [Int]) -> Bool {
        if doneInBook.contains(stage) { return true }
        switch stage {
        case .translation, .secondWave:
            return !items.isEmpty && items.allSatisfy { reveal(stage, $0).outcome != nil }
        case .completion:
            return !items.isEmpty && items.allSatisfy { fillIns[String($0)]?.isDone == true }
        default:
            return true
        }
    }

    /// Toutes les étapes requises sont faites. La fin de séance n'en est pas une :
    /// c'est là qu'on valide.
    func canValidate(_ stages: [DailyStage]) -> Bool {
        stages.filter { $0 != .finish }.allSatisfy(completed.contains)
    }

    // MARK: - Audio

    /// Ne termine jamais rien : se souvient seulement d'où reprendre.
    mutating func recordAudio(_ stage: DailyStage, sentence: Int?) {
        audioSentence[stage.rawValue] = sentence
    }

    func audioSentence(for stage: DailyStage) -> Int? {
        audioSentence[stage.rawValue]
    }

    // MARK: - Exercices

    func reveal(_ stage: DailyStage, _ n: Int) -> RevealState {
        reveals["\(stage.rawValue)-\(n)"] ?? RevealState()
    }

    mutating func setReveal(_ stage: DailyStage, _ n: Int, _ state: RevealState) {
        reveals["\(stage.rawValue)-\(n)"] = state
    }

    func fillIn(_ n: Int) -> FillInAttempt {
        fillIns[String(n)] ?? FillInAttempt()
    }

    mutating func setFillIn(_ n: Int, _ attempt: FillInAttempt) {
        fillIns[String(n)] = attempt
    }
}

/// Où en est le parcours aujourd'hui.
enum DayStatus: Equatable {
    /// Une nouvelle séance est prête à commencer.
    case ready(DailyPlan)
    /// Une séance commencée n'est pas validée : on la reprend, quel que soit le jour
    /// où elle a commencé.
    case inProgress(DailySession, DailyPlan)
    /// La séance du jour est validée. `tomorrow` est `nil` quand le parcours est fini.
    case doneToday(DailySession, DailyPlan, tomorrow: DailyPlan?)
    case courseComplete

    var plan: DailyPlan? {
        switch self {
        case .ready(let plan), .inProgress(_, let plan), .doneToday(_, let plan, _): plan
        case .courseComplete: nil
        }
    }
}

/// Les règles de progression, sans stockage : ce qui se calcule se teste.
///
/// Rien n'est jamais incrémenté. La séance suivante se **déduit** de la dernière
/// validée, ce qui rend la validation idempotente par construction : valider deux
/// fois, rouvrir l'écran ou relancer l'app ne peut pas faire avancer deux fois.
enum DailyCourse {

    static func status(anchorUnit: Int,
                       anchorSetAt: Date,
                       sessions: [DailySession],
                       now: Date,
                       calendar: Calendar = .current,
                       manifest: Manifest = .shared) -> DayStatus {
        // Le jour calendaire local, pas 24 heures : une séance validée à 23 h laisse
        // la suivante disponible à minuit.
        let startOfToday = calendar.startOfDay(for: now)

        if let today = sessions
            .filter({ ($0.completedAt ?? .distantPast) >= startOfToday })
            .max(by: { $0.completedAt! < $1.completedAt! }),
           let plan = Curriculum.plan(unit: today.unit, manifest: manifest) {
            let next = nextUnit(anchorUnit: anchorUnit, anchorSetAt: anchorSetAt, sessions: sessions)
            return .doneToday(today, plan, tomorrow: Curriculum.plan(unit: next, manifest: manifest))
        }

        // Une séance commencée avant un repositionnement manuel est abandonnée.
        if let open = sessions
            .filter({ $0.completedAt == nil && $0.startedAt >= anchorSetAt })
            .max(by: { $0.startedAt < $1.startedAt }),
           let plan = Curriculum.plan(unit: open.unit, manifest: manifest) {
            return .inProgress(open, plan)
        }

        let next = nextUnit(anchorUnit: anchorUnit, anchorSetAt: anchorSetAt, sessions: sessions)
        return Curriculum.plan(unit: next, manifest: manifest).map(DayStatus.ready) ?? .courseComplete
    }

    /// La dernière séance validée décide de la suivante ; les jours manqués ne
    /// comptent pas, aucune leçon n'est sautée.
    static func nextUnit(anchorUnit: Int, anchorSetAt: Date, sessions: [DailySession]) -> Int {
        let validated = sessions.filter { ($0.completedAt ?? .distantPast) >= anchorSetAt && $0.completedAt != nil }
        guard let last = validated.max(by: { $0.completedAt! < $1.completedAt! }) else { return anchorUnit }
        return last.repeatTomorrow ? last.unit : last.unit + 1
    }
}

/// Les gestes du parcours sur le stockage.
@MainActor
struct DailyCourseStore {
    let context: ModelContext
    var manifest: Manifest = .shared
    var calendar: Calendar = .current

    /// Au premier lancement de cette version, le parcours part de la leçon que
    /// l'ancien réglage manuel désignait. Une fin d'écoute enregistrée par l'ancienne
    /// version (`LessonProgress.completedAt`) ne vaut pas validation et ne fait rien
    /// avancer : on ne sait pas si les exercices ont été faits.
    @discardableResult
    func ensureAnchor(legacyLesson: Int) -> CourseAnchor {
        if let existing = anchor() { return existing }
        let lesson = min(max(1, legacyLesson), manifest.lessonCount)
        let anchor = CourseAnchor(unit: lesson, setAt: .distantPast)
        context.insert(anchor)
        save()
        return anchor
    }

    func anchor() -> CourseAnchor? {
        try? context.fetch(FetchDescriptor<CourseAnchor>()).first
    }

    func sessions() -> [DailySession] {
        (try? context.fetch(FetchDescriptor<DailySession>())) ?? []
    }

    func status(now: Date, legacyLesson: Int) -> DayStatus {
        let anchor = ensureAnchor(legacyLesson: legacyLesson)
        return DailyCourse.status(anchorUnit: anchor.unit, anchorSetAt: anchor.setAt,
                                  sessions: sessions(), now: now,
                                  calendar: calendar, manifest: manifest)
    }

    /// La séance à ouvrir : celle en cours s'il y en a une, sinon une nouvelle si la
    /// journée n'a pas déjà la sienne. `nil` quand il n'y a rien à commencer.
    func startOrResume(now: Date, legacyLesson: Int) -> DailySession? {
        switch status(now: now, legacyLesson: legacyLesson) {
        case .inProgress(let session, _):
            return session
        case .ready(let plan):
            let attempt = sessions().filter { $0.unit == plan.unit }.count + 1
            let session = DailySession(unit: plan.unit, attempt: attempt, startedAt: now, stages: plan.stages)
            context.insert(session)
            save()
            return session
        case .doneToday, .courseComplete:
            return nil
        }
    }

    /// Valide une séance dont toutes les étapes sont faites. Sans effet — et `false`
    /// — si elle l'est déjà ou s'il manque une étape.
    @discardableResult
    func validate(_ session: DailySession, now: Date) -> Bool {
        guard session.completedAt == nil,
              let plan = Curriculum.plan(unit: session.unit, manifest: manifest),
              session.progress.canValidate(plan.stages)
        else { return false }
        session.completedAt = now
        session.updatedAt = now
        save()
        return true
    }

    /// Replace le parcours sur une leçon. La séance en cours, s'il y en a une, est
    /// abandonnée ; les séances validées restent dans l'historique.
    func reposition(toLesson lesson: Int, now: Date, legacyLesson: Int) {
        let anchor = ensureAnchor(legacyLesson: legacyLesson)
        anchor.unit = min(max(1, lesson), manifest.lessonCount)
        anchor.setAt = now
        save()
    }

    func setRepeatTomorrow(_ session: DailySession, _ value: Bool) {
        session.repeatTomorrow = value
        save()
    }

    func save() {
        try? context.save()
    }
}
