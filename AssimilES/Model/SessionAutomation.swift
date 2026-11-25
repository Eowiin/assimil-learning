import Foundation
import SwiftData

/// Les deux parties du bloc 4, dans l'ordre.
enum AutomationPart: String, CaseIterable, Identifiable, Hashable {
    case speed, writing

    var id: String { rawValue }
    /// La clé dans `StudyBlockProgress.parts`, posée quand le récapitulatif est arrivé.
    var key: String { "\(StudyBlock.automation.rawValue).\(rawValue)" }

    var title: String {
        switch self {
        case .speed: "Oral en rafale"
        case .writing: "Court écrit"
        }
    }

    var symbol: String {
        switch self {
        case .speed: "bolt.horizontal.circle"
        case .writing: "pencil.line"
        }
    }
}

/// Le bloc 4 de la séance (`docs/moteur-adaptatif.md`, étape 4e) : trois minutes de
/// questions en rafale sur un thème familier, avec les mots déjà sus, puis un court écrit
/// (sa longueur selon le niveau, étape 5b) qui rappelle l'objectif à réinjecter.
@MainActor
enum SessionAutomation {
    /// La rafale vise trois minutes, sans couper (cinq jusqu'à l'étape 5a).
    static let speedSeconds: Double = 3 * 60

    /// La longueur de l'écrit (étape 5b) : un message court pour un débutant (A0, A1), un
    /// paragraphe au-delà. « Faire corriger » à la borne basse, avertissement au-delà de
    /// la haute.
    nonisolated static func writingWords(level: String?) -> ClosedRange<Int> {
        LearnerLevel.isBeginner(level) ? 15...30 : 50...80
    }

    // MARK: - La rafale

    /// Le profil de la rafale : automatiser ce qui est déjà su, pas apprendre. Ni
    /// objectif ni mots du jour (c'est le jeu de rôle du bloc 3) ; la réplique est
    /// mesurée sur les seuls mots connus. Le niveau est celui de l'apprenant (`LearnerLevel`).
    static func speedProfile(for session: StudySession, pack: CurriculumPack,
                             in context: ModelContext) -> ConversationProfile {
        let estimate = PlacementStore.latestCompleted(language: pack.language, in: context)?.lexiconEstimate ?? 0
        let states = (try? context.fetch(FetchDescriptor<LexemeState>())) ?? []
        let level = LearnerLevel.current(pack: pack, in: context) ?? session.objectiveID.flatMap(pack.objective)?.level
        return ConversationProfile(level: level, mode: "speed",
                                   allowedLemmas: KnownVocabulary.lemmas(pack: pack, estimate: estimate, states: states))
    }

    /// Le thème de la rafale : un thème déjà lu, celui du cycle d'avant le plus récent
    /// qui en diffère (le cycle précédent du même jour compte) ; au tout premier cycle,
    /// celui du jour.
    static func familiarTheme(for session: StudySession, pack: CurriculumPack,
                              in context: ModelContext) -> CurriculumPack.Theme? {
        let started = session.startedAt
        let language = session.language
        let earlier = (try? context.fetch(FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.startedAt < started && $0.language == language },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []
        let theme = { (id: String?) in id.flatMap { id in pack.themes.first { $0.id == id } } }
        return earlier.lazy.filter { $0.theme != session.theme }.compactMap { theme($0.theme) }.first
            ?? theme(session.theme)
    }

    // MARK: - L'écrit

    /// L'objectif que l'écrit rappelle et que le correcteur juge : celui à réinjecter
    /// s'il y en a un, sinon celui du cycle. Un cycle 2 ou plus n'en a pas : son
    /// objectif est déjà un objectif repris (`DailyPlanner.newCycle`).
    static func writingObjective(for session: StudySession, pack: CurriculumPack) -> CurriculumPack.Objective? {
        session.reinjectObjectiveID.flatMap(pack.objective) ?? session.objectiveID.flatMap(pack.objective)
    }

    /// La consigne, composée sans l'IA : le thème du jour, l'objectif à employer et,
    /// si l'orthographe revient dans les fautes d'avant (`patterns`), un rappel des accents.
    static func writingPrompt(for session: StudySession, pack: CurriculumPack, level: String?,
                              patterns: ErrorPatterns = ErrorPatterns()) -> String {
        let theme = pack.themes.first { $0.id == session.theme }
        let subject = theme.map { "sur ce thème : \($0.fr.lowercasedFirst)" } ?? "sur ta journée"
        let range = writingWords(level: level)
        let words = "\(range.lowerBound) à \(range.upperBound) mots"
        var prompt = "Écris \(words) \(subject)."
        if let objective = writingObjective(for: session, pack: pack) {
            prompt += " Emploie ce point : « \(objective.title) »."
        }
        if patterns.spellingRecurs { prompt += " Attention aux accents écrits." }
        return prompt
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.contains(where: \.isLetter) }
            .count
    }

    /// L'écrit du cycle, s'il a été envoyé : le dernier écrit depuis le début du cycle.
    static func writing(for session: StudySession, in context: ModelContext) -> WritingRecord? {
        let since = session.startedAt
        let language = session.language
        return ((try? context.fetch(FetchDescriptor<WritingRecord>(
            predicate: #Predicate { $0.writtenAt >= since && $0.language == language },
            sortBy: [SortDescriptor(\.writtenAt, order: .reverse)]))) ?? []).first
    }

    /// La correction arrivée : gardée sur l'écrit, l'objectif jugé au journal (une
    /// réussite au plus), les mots produits, la partie cochée. Une fois par écrit.
    static func recordWriting(_ review: WritingReview, on record: WritingRecord, in session: StudySession,
                              pack: CurriculumPack, at date: Date, in context: ModelContext) throws {
        guard record.review == nil else { return }
        record.review = try JSONEncoder().encode(review)
        try SessionConversation.recordProduction(uses: review.objectiveUses, lemmas: review.lemmasProduced,
                                                 objectiveID: record.objectiveID,
                                                 source: ObjectiveEvidence.Source.writing,
                                                 pack: pack, at: date, in: context)
        StudySessionProgress.markPart(AutomationPart.writing.key, in: session, at: date)
    }
}

extension WritingRecord {
    /// La correction gardée, nil tant qu'elle n'est pas arrivée.
    var writingReview: WritingReview? {
        review.flatMap { try? JSONDecoder().decode(WritingReview.self, from: $0) }
    }
}

extension String {
    /// « Au marché » devient « au marché », pour une consigne qui se lit d'une traite.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
