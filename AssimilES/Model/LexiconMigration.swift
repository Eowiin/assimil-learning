import Foundation
import OSLog
import SwiftData

/// Reprend dans le lexique adaptatif (`LexemeState`) les mots déjà travaillés en
/// révision Assimil : une carte de vocabulaire existe, le mot a donc été **vu** ; sa
/// carte `recognize` connue le fait **reconnu** ; sa carte `recall` connue, **actif**.
///
/// Le statut ne fait que monter : la passe est sans effet sur un mot déjà plus avancé,
/// et la repasser ne change rien. Au démarrage, elle ne passe qu'une fois
/// (`finishIfNeeded`, inscrite dans `DataMigration`) ; la séance adaptative pourra
/// l'appeler à nouveau (`absorbAssimilCards`) tant que la révision Assimil continue.
///
/// La date d'un mot reconnu ou actif est sa dernière révision : le moment exact où
/// la carte est devenue connue n'est pas gardé, celui-là est le plus proche.
@MainActor
enum LexiconMigration {

    static let completionKey = "lexicon-from-assimil-vocab"
    static let source = "assimil"

    struct Report: Equatable {
        var created = 0
        var raised = 0
    }

    enum Outcome: Equatable {
        case alreadyDone
        case finished(Report)
        case failed
    }

    /// `ranks` : le rang de chaque lemme dans le lexique du paquet, lu seulement si la
    /// passe a lieu ; vide si le paquet manque, et les rangs resteront nil.
    @discardableResult
    static func finishIfNeeded(ranks: () -> [String: Int], in context: ModelContext, now: Date = .now) -> Outcome {
        let key = completionKey
        do {
            let done = try context.fetchCount(FetchDescriptor<DataMigration>(predicate: #Predicate { $0.key == key }))
            if done > 0 { return .alreadyDone }
            let report = try absorbAssimilCards(ranks: ranks(), in: context, now: now)
            context.insert(DataMigration(key: key, completedAt: now))
            try context.save()
            log.info("lexique : \(report.created) mots repris d'Assimil, \(report.raised) statuts montés")
            return .finished(report)
        } catch {
            log.error("reprise du lexique interrompue : \(String(describing: error), privacy: .public)")
            context.rollback()
            return .failed
        }
    }

    /// Une passe, sans inscription ni `save`.
    static func absorbAssimilCards(ranks: [String: Int], language: String = "es",
                                   in context: ModelContext, now: Date = .now,
                                   calendar: Calendar = .current) throws -> Report {
        let recognize = Card.Angle.recognize, recall = Card.Angle.recall
        let cards = try context.fetch(FetchDescriptor<Card>(predicate: #Predicate {
            $0.isActive && ($0.angle == recognize || $0.angle == recall)
        }))
        let byLemma = Dictionary(grouping: cards.filter { $0.language == language }) { $0.vocabItem?.lemma ?? "" }
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<LexemeState>()).filter { $0.language == language }.map { ($0.lemma, $0) },
            uniquingKeysWith: { first, _ in first })

        var report = Report()
        for (lemma, cards) in byLemma where !lemma.isEmpty {
            let recognizeCard = cards.first { $0.angle == recognize }
            let recallCard = cards.first { $0.angle == recall }
            let firstSeen = cards.map(\.createdAt).min() ?? now

            let (status, since): (String, Date?) =
                if let recallCard, recallCard.isKnown(calendar: calendar) {
                    (LexemeState.Status.active, recallCard.lastReviewedAt)
                } else if let recognizeCard, recognizeCard.isKnown(calendar: calendar) {
                    (LexemeState.Status.recognized, recognizeCard.lastReviewedAt)
                } else {
                    (LexemeState.Status.seen, nil)
                }

            let state: LexemeState
            if let found = existing[lemma] {
                state = found
                if firstSeen < state.firstSeenAt { state.firstSeenAt = firstSeen }
            } else {
                state = LexemeState(language: language, lemma: lemma, rank: ranks[lemma], source: source, at: firstSeen)
                state.seenCount = 1
                context.insert(state)
                report.created += 1
            }
            if state.raise(to: status, at: since ?? now), existing[lemma] != nil { report.raised += 1 }
            if state.rank == nil { state.rank = ranks[lemma] }
        }
        return report
    }

    private static let log = Logger(subsystem: "AssimilES", category: "lexique")
}
