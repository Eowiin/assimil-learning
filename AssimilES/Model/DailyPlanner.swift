import Foundation
import SwiftData

/// Le choix de la séance adaptative (`docs/moteur-adaptatif.md`, étapes 4 et 5) :
/// l'objectif, l'objectif à réinjecter, les mots nouveaux, le thème.
///
/// Une séance est un cycle court ; on en enchaîne autant qu'on a de temps. Le premier
/// cycle du jour est créé au premier passage sur l'accueil : il fait avancer le parcours
/// et tire les mots nouveaux. Les suivants se lancent à la main (`newCycle`), chacun sur
/// un autre objectif, repris : refaire trois fois de suite le même n'apprendrait rien.
@MainActor
enum DailyPlanner {

    /// Les mots nouveaux d'une journée (la route en accepte 6 à 8), tirés au premier
    /// cycle ; les suivants les reprennent.
    static let newLemmaCount = 7
    /// Les catégories des mots nouveaux : des mots pleins, comme au test de vocabulaire.
    static let newLemmaPOS = VocabularyTest.askedPOS
    /// Le temps visé par bloc, affiché, jamais imposé : un cycle fait un quart d'heure.
    static let minutesPerBlock = 5

    /// Le cycle en cours du jour (le dernier lancé), et le premier créé si besoin. Nil
    /// sans placement validé : c'est lui qui donne le point de départ.
    @discardableResult
    static func today(pack: CurriculumPack, now: Date = .now, calendar: Calendar = .current,
                      in context: ModelContext) throws -> StudySession? {
        let language = pack.language
        if let current = try cycles(language: language, day: now, calendar: calendar, in: context).last {
            return current
        }
        guard let placement = PlacementStore.latestCompleted(language: language, in: context) else { return nil }

        let objective = try advanceObjective(pack: pack, now: now, in: context)
        let session = StudySession(language: language, day: now, objectiveID: objective?.objectiveID,
                                   startedAt: now, calendar: calendar)
        session.reinjectObjectiveID = try reinjectCandidate(pack: pack, excluding: objective?.objectiveID, in: context)
        session.newLemmas = try newLemmas(pack: pack, frontier: placement.lexiconEstimate, in: context)
        session.theme = try nextTheme(pack: pack, in: context)
        context.insert(session)
        try context.save()
        return session
    }

    /// Les cycles d'un jour, dans l'ordre.
    static func cycles(language: String, day: Date, calendar: Calendar = .current,
                       in context: ModelContext) throws -> [StudySession] {
        let start = calendar.startOfDay(for: day)
        return try context.fetch(FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.day == start && $0.language == language },
            sortBy: [SortDescriptor(\.cycle)]))
    }

    /// Un cycle de plus, une fois le dernier fait. Il ne fait pas avancer le parcours (le
    /// premier cycle de demain s'en charge) : son objectif est repris, un « à réinjecter »
    /// d'abord, sinon un acquis à entretenir, le moins revu en premier et pas déjà
    /// travaillé aujourd'hui. Pas de mots nouveaux : le texte reprend ceux du jour. Un
    /// autre thème, pour un autre texte. Nil sans cycle fini à suivre.
    @discardableResult
    static func newCycle(pack: CurriculumPack, now: Date = .now, calendar: Calendar = .current,
                         in context: ModelContext) throws -> StudySession? {
        let language = pack.language
        let today = try cycles(language: language, day: now, calendar: calendar, in: context)
        guard let first = today.first, let last = today.last, last.completedAt != nil else { return nil }
        let worked = Set(today.compactMap(\.objectiveID))
        let objective = try revisitCandidate(pack: pack, excluding: worked, in: context)
            // Tout a déjà été repris aujourd'hui : on recommence le tour, sans refaire
            // l'objectif du cycle qui vient de finir.
            ?? revisitCandidate(pack: pack, excluding: Set([last.objectiveID].compactMap { $0 }), in: context)
            ?? first.objectiveID
        let session = StudySession(language: language, day: now, objectiveID: objective, startedAt: now,
                                   cycle: last.cycle + 1, calendar: calendar)
        session.newLemmas = first.newLemmas
        session.theme = try nextTheme(pack: pack, in: context)
        context.insert(session)
        try context.save()
        return session
    }

    // MARK: L'objectif

    /// L'objectif du jour : l'actif ; s'il l'est depuis deux jours sans être acquis, il
    /// passe « à réinjecter » et le suivant s'ouvre. Sans actif (il vient d'être acquis),
    /// le premier verrouillé dans l'ordre du parcours. Nil quand tout est acquis.
    static func advanceObjective(pack: CurriculumPack, now: Date, in context: ModelContext) throws -> ObjectiveProgress? {
        let progresses = try progressByObjective(pack: pack, in: context)
        let active = ObjectiveProgress.Status.active
        if let current = pack.objectives.lazy.compactMap({ progresses[$0.id] }).first(where: { $0.status == active }) {
            guard ObjectiveTracker.softUnlockIfDue(current, now: now) else { return current }
        }
        let locked = ObjectiveProgress.Status.locked
        guard let next = pack.objectives.lazy.compactMap({ progresses[$0.id] }).first(where: { $0.status == locked })
        else { return nil }
        ObjectiveTracker.activate(next, at: now)
        return next
    }

    /// L'objectif à rappeler : parmi ceux laissés de côté, celui dont la dernière
    /// preuve est la plus ancienne (jamais revu d'abord), dans l'ordre du parcours à
    /// égalité.
    static func reinjectCandidate(pack: CurriculumPack, excluding: String?, in context: ModelContext) throws -> String? {
        try leastRecent(ObjectiveProgress.Status.toReinject, pack: pack,
                        excluding: Set([excluding].compactMap { $0 }), in: context)
    }

    /// L'objectif d'un cycle repris : un « à réinjecter », sinon un acquis à entretenir,
    /// chaque fois le moins revu.
    static func revisitCandidate(pack: CurriculumPack, excluding: Set<String>, in context: ModelContext) throws -> String? {
        try leastRecent(ObjectiveProgress.Status.toReinject, pack: pack, excluding: excluding, in: context)
            ?? leastRecent(ObjectiveProgress.Status.acquired, pack: pack, excluding: excluding, in: context)
    }

    /// Parmi les objectifs d'un statut, celui dont la dernière preuve est la plus ancienne
    /// (jamais revu d'abord), dans l'ordre du parcours à égalité.
    private static func leastRecent(_ status: String, pack: CurriculumPack, excluding: Set<String>,
                                    in context: ModelContext) throws -> String? {
        let progresses = try progressByObjective(pack: pack, in: context)
        let order = Dictionary(uniqueKeysWithValues: pack.objectives.enumerated().map { ($1.id, $0) })
        return progresses.values
            .filter { $0.status == status && !excluding.contains($0.objectiveID) && order[$0.objectiveID] != nil }
            .min { a, b in
                let ta = a.lastEvidenceAt ?? .distantPast, tb = b.lastEvidenceAt ?? .distantPast
                return ta != tb ? ta < tb : (order[a.objectiveID] ?? 0) < (order[b.objectiveID] ?? 0)
            }?.objectiveID
    }

    private static func progressByObjective(pack: CurriculumPack, in context: ModelContext) throws -> [String: ObjectiveProgress] {
        let language = pack.language
        let all = try context.fetch(FetchDescriptor<ObjectiveProgress>()).filter { $0.language == language }
        return Dictionary(all.map { ($0.objectiveID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Les mots et le thème

    /// Les premiers mots pleins du lexique au-delà de la frontière du placement, que
    /// l'état ne connaît pas encore (pas même vus). Un mot vu au bloc 2 n'est plus
    /// proposé : la frontière avance d'elle-même.
    static func newLemmas(pack: CurriculumPack, frontier: Int, count: Int = newLemmaCount,
                          in context: ModelContext) throws -> [String] {
        let language = pack.language
        let known = Set(try context.fetch(FetchDescriptor<LexemeState>()).filter { $0.language == language }.map(\.lemma))
        return Array(pack.lexicon.dropFirst(max(0, frontier))
            .lazy
            .filter { newLemmaPOS.contains($0.pos) && !known.contains($0.lemma) }
            .prefix(count)
            .map(\.lemma))
    }

    /// Le thème qui suit celui du dernier cycle, en boucle.
    static func nextTheme(pack: CurriculumPack, in context: ModelContext) throws -> String? {
        guard !pack.themes.isEmpty else { return nil }
        let language = pack.language
        var descriptor = FetchDescriptor<StudySession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 10
        let last = try context.fetch(descriptor).first { $0.language == language && $0.theme != nil }?.theme
        guard let last, let index = pack.themes.firstIndex(where: { $0.id == last }) else {
            return pack.themes.first?.id
        }
        return pack.themes[(index + 1) % pack.themes.count].id
    }
}

// MARK: - L'avancement

@MainActor
enum StudySessionProgress {
    /// Un bloc fait, avec le temps qu'il a pris ; la séance est faite quand les quatre
    /// sont faits ou passés.
    static func complete(_ block: StudyBlock, seconds: Double, in session: StudySession, at date: Date) {
        var blocks = session.blocks
        blocks.add(seconds, to: block)
        blocks.complete(block, at: date)
        update(session, blocks, at: date)
    }

    static func skip(_ block: StudyBlock, seconds: Double, in session: StudySession, at date: Date) {
        var blocks = session.blocks
        blocks.add(seconds, to: block)
        blocks.skip(block, at: date)
        update(session, blocks, at: date)
    }

    /// Une partie d'un bloc faite (la micro-leçon lue, les sons travaillés…).
    static func markPart(_ part: String, in session: StudySession, at date: Date) {
        var blocks = session.blocks
        guard blocks.parts[part] == nil else { return }
        blocks.parts[part] = date
        session.blocks = blocks
    }

    /// Le temps passé dans un bloc qu'on quitte sans le finir.
    static func addTime(_ seconds: Double, to block: StudyBlock, in session: StudySession) {
        var blocks = session.blocks
        blocks.add(seconds, to: block)
        session.blocks = blocks
    }

    private static func update(_ session: StudySession, _ blocks: StudyBlockProgress, at date: Date) {
        session.blocks = blocks
        if blocks.isDone, session.completedAt == nil { session.completedAt = date }
    }
}
