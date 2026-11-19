import Foundation

/// La correction d'un écrit (`POST /writing/review`) : les phrases fautives, le texte
/// entier corrigé, l'objectif jugé (null sans objectif demandé) et les lemmes produits
/// (null sans spaCy).
struct WritingReview: Codable, Equatable, Sendable {
    var corrections: [ConversationCorrection]
    var correctedText: String
    var objectiveUses: [ObjectiveUse]? = nil
    var lemmasProduced: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case corrections, correctedText = "corrected_text", objectiveUses = "objective_uses",
             lemmasProduced = "lemmas_produced"
    }
}

/// Ce que l'écrit attend du serveur. `WritingClient` le joint par Tailscale ; les
/// tests passent un faux.
protocol WritingService: Sendable {
    func review(text: String, level: String?, objective: ConversationObjective?) async throws -> WritingReview
}

struct WritingClient: WritingService {
    let baseURL: URL
    var session: URLSession = .shared

    /// Mistral corrige un texte de cent mots en quelques secondes.
    static let timeout: TimeInterval = 90

    private struct Body: Encodable {
        let text: String
        let level: String?
        let objective: ConversationObjective?
    }

    func review(text: String, level: String?, objective: ConversationObjective?) async throws -> WritingReview {
        let body = try JSONEncoder().encode(Body(text: text, level: level, objective: objective))
        return try await HomeServer.post("writing/review", base: baseURL, body: body,
                                         contentType: "application/json", timeout: Self.timeout,
                                         session: session, as: WritingReview.self)
    }
}

#if DEBUG
/// Le correcteur imaginaire des tests d'interface (`ASSIMIL_FAKE_SERVER`).
struct FakeWritingService: WritingService {
    func review(text: String, level: String?, objective: ConversationObjective?) async throws -> WritingReview {
        WritingReview(
            corrections: [ConversationCorrection(said: "Ayer fui al mercado y compre pan.",
                                                 corrected: "Ayer fui al mercado y compré pan.",
                                                 explanation: "Le passé simple prend un accent écrit à la première personne.",
                                                 category: .spelling, tag: "accent écrit")],
            correctedText: text,
            objectiveUses: objective == nil ? nil : [
                ObjectiveUse(said: "Ayer fui al mercado.", valid: true, analysis: "L'objectif est employé."),
            ],
            lemmasProduced: ["mercado", "pan"])
    }
}
#endif
