import Foundation
import SwiftData

/// Le bloc 3 de la séance (`docs/moteur-adaptatif.md`, étape 4d) : le jeu de rôle de
/// l'objectif du jour. Le profil le règle ; le récapitulatif donne les preuves de
/// l'objectif et les mots produits.
@MainActor
enum SessionConversation {
    /// La partie du bloc cochée quand un récapitulatif est arrivé.
    static let part = "\(StudyBlock.conversation.rawValue).roleplay"

    /// Les mots du jour compris : ceux que le texte du bloc 2 a vraiment employés, pas
    /// les sept proposés. Sans texte, aucun.
    static func dayWords(of session: StudySession) -> [String] {
        Absorption.text(of: session)?.newUsed.filter { !$0.isEmpty } ?? []
    }

    /// Le profil du jeu de rôle, nil sans objectif. Le niveau est celui de l'objectif,
    /// comme pour le texte du bloc 2. Pas de faute à surveiller : la scène reste sur
    /// l'objectif.
    static func profile(for session: StudySession, pack: CurriculumPack,
                        in context: ModelContext) -> ConversationProfile? {
        guard let objective = session.objectiveID.flatMap(pack.objective) else { return nil }
        let estimate = PlacementStore.latestCompleted(language: pack.language, in: context)?.lexiconEstimate ?? 0
        let states = (try? context.fetch(FetchDescriptor<LexemeState>())) ?? []
        let day = dayWords(of: session)
        var allowed = KnownVocabulary.lemmas(pack: pack, estimate: estimate, states: states)
        let known = Set(allowed)
        allowed += day.filter { !known.contains($0) }
        return ConversationProfile(words: Array(day.prefix(ConversationProfile.maxWords)),
                                   level: objective.level, objective: ConversationObjective(objective),
                                   mode: "roleplay", allowedLemmas: allowed)
    }

    /// Le récapitulatif d'une conversation, à inscrire une fois : chaque emploi de
    /// l'objectif va au journal (une réussite au plus pour la conversation), les mots
    /// produits montent, la partie du bloc est cochée.
    static func record(_ review: ConversationReview, in session: StudySession, pack: CurriculumPack,
                       at date: Date, in context: ModelContext) throws {
        if let objectiveID = session.objectiveID, let uses = review.objectiveUses, !uses.isEmpty {
            let progress = try ObjectiveTracker.progress(language: pack.language, objectiveID: objectiveID,
                                                         at: date, in: context)
            let evidences = uses.map {
                ObjectiveEvidence(objectiveKey: progress.key, at: date, source: ObjectiveEvidence.Source.conversation,
                                  valid: $0.valid, said: $0.said, analysis: $0.analysis)
            }
            ObjectiveTracker.recordProduction(evidences, on: progress, in: context)
        }
        try KnownVocabulary.recordProduction(review.lemmasProduced ?? [], language: pack.language, ranks: pack.ranks,
                                             source: ObjectiveEvidence.Source.conversation, at: date, in: context)
        StudySessionProgress.markPart(part, in: session, at: date)
    }

    /// Le bilan du jour : les emplois de l'objectif en conversation depuis le début de
    /// la séance, réussis et tentés.
    static func tally(for session: StudySession, language: String,
                      in context: ModelContext) -> (valid: Int, total: Int) {
        guard let objectiveID = session.objectiveID else { return (0, 0) }
        let key = AdaptiveKey.make(language: language, objectiveID)
        let since = session.day
        let source = ObjectiveEvidence.Source.conversation
        let evidences = (try? context.fetch(FetchDescriptor<ObjectiveEvidence>(
            predicate: #Predicate { $0.objectiveKey == key && $0.at >= since && $0.source == source }))) ?? []
        return (evidences.filter(\.valid).count, evidences.count)
    }
}
