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

/// Le bloc 4 de la séance (`docs/moteur-adaptatif.md`, étape 4e) : cinq minutes de
/// questions en rafale sur l'objectif du jour, puis un écrit de 80 à 120 mots qui
/// rappelle l'objectif à réinjecter.
@MainActor
enum SessionAutomation {
    /// La rafale vise cinq minutes, sans couper.
    static let speedSeconds: Double = 5 * 60
    static let writingWords = 80...120

    // MARK: - La rafale

    /// Le profil de la rafale : comme le jeu de rôle, en `speed`, avec les mots à rendre
    /// actifs.
    static func speedProfile(for session: StudySession, pack: CurriculumPack,
                             in context: ModelContext) -> ConversationProfile? {
        guard var profile = SessionConversation.profile(for: session, pack: pack, in: context) else { return nil }
        profile.mode = "speed"
        let states = (try? context.fetch(FetchDescriptor<LexemeState>())) ?? []
        profile.words = activeWords(day: SessionConversation.dayWords(of: session), states: states,
                                    language: pack.language)
        return profile
    }

    /// Les mots que la rafale fait dire : ceux du jour d'abord, puis les reconnus pas
    /// encore actifs, les plus récemment reconnus d'abord. Cinq au plus.
    static func activeWords(day: [String], states: [LexemeState], language: String) -> [String] {
        let recognized: [String] = states
            .filter { $0.language == language && $0.status == LexemeState.Status.recognized }
            .sorted { first, second in
                let a = first.recognizedAt ?? .distantPast, b = second.recognizedAt ?? .distantPast
                return a != b ? a > b : first.lemma < second.lemma
            }
            .map(\.lemma)
        var seen = Set<String>()
        return Array((day + recognized).filter { seen.insert($0).inserted }.prefix(ConversationProfile.maxWords))
    }

    // MARK: - L'écrit

    /// L'objectif que l'écrit rappelle et que le correcteur juge : celui à réinjecter
    /// s'il y en a un (l'écrit est son seul moment), sinon celui du jour.
    static func writingObjective(for session: StudySession, pack: CurriculumPack) -> CurriculumPack.Objective? {
        session.reinjectObjectiveID.flatMap(pack.objective) ?? session.objectiveID.flatMap(pack.objective)
    }

    /// La consigne, composée sans l'IA : le thème du jour et l'objectif à employer.
    static func writingPrompt(for session: StudySession, pack: CurriculumPack) -> String {
        let theme = pack.themes.first { $0.id == session.theme }
        let subject = theme.map { "sur ce thème : \($0.fr.lowercasedFirst)" } ?? "sur ta journée"
        let words = "\(writingWords.lowerBound) à \(writingWords.upperBound) mots"
        guard let objective = writingObjective(for: session, pack: pack) else { return "Écris \(words) \(subject)." }
        return "Écris \(words) \(subject). Emploie ce point : « \(objective.title) »."
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.contains(where: \.isLetter) }
            .count
    }

    /// L'écrit de la séance, s'il a été envoyé : le dernier écrit depuis le début du jour.
    static func writing(for session: StudySession, in context: ModelContext) -> WritingRecord? {
        let since = session.day
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
