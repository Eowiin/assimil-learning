import Foundation
import SwiftData

/// Une conversation terminée, gardée sur l'iPhone (le serveur ne garde rien). Rien
/// ne l'affiche après le récapitulatif : elle attend le profil d'apprenant, qui
/// lira les fautes relevées au fil des conversations.
///
/// L'échange et les corrections sont rangés en JSON, dans la forme même où ils
/// circulent avec le serveur : pas de table par réplique pour un historique qu'on
/// relit en entier ou pas du tout.
@Model
final class ConversationRecord {
    #Index<ConversationRecord>([\.startedAt])

    var startedAt: Date = Date.now
    var endedAt: Date = Date.now
    var language: String = "es"
    /// `[ConversationMessage]` en JSON.
    var transcript: Data = Data()
    /// `[ConversationCorrection]` en JSON. Nil tant que le récapitulatif n'a pas
    /// été fait (serveur injoignable au moment de terminer, par exemple).
    var corrections: Data?

    init(startedAt: Date, endedAt: Date, messages: [ConversationMessage]) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = (try? JSONEncoder().encode(messages)) ?? Data()
    }

    var messages: [ConversationMessage] {
        (try? JSONDecoder().decode([ConversationMessage].self, from: transcript)) ?? []
    }

    var reviewedCorrections: [ConversationCorrection]? {
        get { corrections.flatMap { try? JSONDecoder().decode([ConversationCorrection].self, from: $0) } }
        set { corrections = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}
