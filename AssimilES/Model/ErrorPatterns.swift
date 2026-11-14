import Foundation

/// Les fautes de conversation qui reviennent, regroupées par point (`tag`)
/// (`docs/module-profil.md`, étape 2).
///
/// Rien n'est stocké : c'est une projection des `ConversationRecord`, recalculée à
/// la fin d'une conversation.
struct ErrorPatterns: Equatable {

    /// Les corrections d'une conversation gardée.
    struct Conversation {
        let endedAt: Date
        let corrections: [ConversationCorrection]
    }

    struct Pattern: Equatable {
        /// Le point tel que l'IA l'a écrit la dernière fois.
        var tag: String
        var category: ConversationCorrection.Category?
        /// Le nombre de conversations où le point revient : deux fautes dans la même
        /// conversation n'en font qu'une.
        var conversations: Int
        var lastSeen: Date
        /// Les trois dernières phrases fautives, la plus récente d'abord.
        var examples: [ConversationCorrection]
    }

    /// Par point replié (`key`).
    private(set) var patterns: [String: Pattern] = [:]

    init(conversations: [Conversation]) {
        for conversation in conversations.sorted(by: { $0.endedAt < $1.endedAt }) {
            var seen = Set<String>()
            for correction in conversation.corrections {
                // Une correction gardée avant les étiquettes n'a pas de point.
                guard let tag = correction.tag, let key = Self.key(tag) else { continue }
                var pattern = patterns[key] ?? Pattern(tag: tag, category: correction.category, conversations: 0,
                                                       lastSeen: conversation.endedAt, examples: [])
                if seen.insert(key).inserted { pattern.conversations += 1 }
                pattern.tag = tag
                pattern.category = correction.category ?? pattern.category
                pattern.lastSeen = conversation.endedAt
                pattern.examples = Array(([correction] + pattern.examples).prefix(3))
                patterns[key] = pattern
            }
        }
    }

    init(records: [ConversationRecord]) {
        self.init(conversations: records.compactMap { record in
            record.reviewedCorrections.map { Conversation(endedAt: record.endedAt, corrections: $0) }
        })
    }

    /// Le point d'une faute, replié : l'IA écrit le même point de plusieurs façons
    /// (« Ser/Estar », « ser / estar »). Nil pour un point vide.
    static func key(_ tag: String) -> String? {
        let folded = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .filter { !$0.isWhitespace }
        return folded.isEmpty ? nil : folded
    }

    /// Le point d'une correction, s'il a déjà été relevé.
    func pattern(for correction: ConversationCorrection) -> Pattern? {
        correction.tag.flatMap(Self.key).flatMap { patterns[$0] }
    }

    /// Les points les plus fréquents, puis les plus récents.
    var mostFrequent: [Pattern] {
        patterns.values.sorted { a, b in
            a.conversations != b.conversations ? a.conversations > b.conversations : a.lastSeen > b.lastSeen
        }
    }
}
