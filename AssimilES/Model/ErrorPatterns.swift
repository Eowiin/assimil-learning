import Foundation
import SwiftData

/// Les fautes qui reviennent, regroupées par point (`tag`), dans les conversations
/// et les écrits corrigés (`docs/module-profil.md`, étape 2).
///
/// Rien n'est stocké : c'est une projection des `ConversationRecord` et des
/// `WritingRecord`, recalculée quand on en a besoin.
struct ErrorPatterns: Equatable {

    /// Les corrections d'une production gardée : une conversation ou un écrit.
    struct Production {
        enum Kind { case conversation, writing }

        let date: Date
        let kind: Kind
        let corrections: [ConversationCorrection]
    }

    struct Pattern: Equatable {
        /// Le point tel que l'IA l'a écrit la dernière fois.
        var tag: String
        var category: ConversationCorrection.Category?
        /// Le nombre de conversations et d'écrits où le point revient : deux fautes
        /// dans la même production n'en font qu'une.
        var conversations: Int
        var writings: Int
        var lastSeen: Date
        /// Les trois dernières phrases fautives, la plus récente d'abord.
        var examples: [ConversationCorrection]

        /// Un écrit compte comme une conversation : c'est la somme qui classe.
        var productions: Int { conversations + writings }
    }

    /// Par point replié (`key`).
    private(set) var patterns: [String: Pattern] = [:]
    /// Le nombre de productions où l'orthographe a été reprise, quel qu'en soit le point.
    private(set) var spellingProductions = 0

    /// L'orthographe qui revient fait ajouter un rappel à la consigne de l'écrit.
    static let spellingThreshold = 2
    /// Un point devient la faute à surveiller à partir de deux productions.
    static let watchThreshold = 2

    init(productions: [Production] = []) {
        for production in productions.sorted(by: { $0.date < $1.date }) {
            var seen = Set<String>()
            for correction in production.corrections {
                // Une correction gardée avant les étiquettes n'a pas de point.
                guard let tag = correction.tag, let key = Self.key(tag) else { continue }
                var pattern = patterns[key] ?? Pattern(tag: tag, category: correction.category, conversations: 0,
                                                       writings: 0, lastSeen: production.date, examples: [])
                if seen.insert(key).inserted {
                    switch production.kind {
                    case .conversation: pattern.conversations += 1
                    case .writing: pattern.writings += 1
                    }
                }
                pattern.tag = tag
                pattern.category = correction.category ?? pattern.category
                pattern.lastSeen = production.date
                pattern.examples = Array(([correction] + pattern.examples).prefix(3))
                patterns[key] = pattern
            }
            if production.corrections.contains(where: { $0.category == .spelling }) { spellingProductions += 1 }
        }
    }

    /// Les conversations et les écrits corrigés ; ceux sans correction arrivée ne
    /// comptent pas.
    init(conversations: [ConversationRecord], writings: [WritingRecord]) {
        self.init(productions:
            conversations.compactMap { record in
                record.reviewedCorrections.map { Production(date: record.endedAt, kind: .conversation, corrections: $0) }
            } + writings.compactMap { record in
                record.writingReview.map { Production(date: record.writtenAt, kind: .writing, corrections: $0.corrections) }
            })
    }

    /// Lu depuis le stockage. `before` : seulement les productions d'avant cette date,
    /// pour le récapitulatif d'un écrit relu plus tard.
    @MainActor
    static func load(in context: ModelContext, before date: Date? = nil) -> ErrorPatterns {
        var conversations = (try? context.fetch(FetchDescriptor<ConversationRecord>())) ?? []
        var writings = (try? context.fetch(FetchDescriptor<WritingRecord>())) ?? []
        if let date {
            conversations = conversations.filter { $0.endedAt < date }
            writings = writings.filter { $0.writtenAt < date }
        }
        return ErrorPatterns(conversations: conversations, writings: writings)
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
            a.productions != b.productions ? a.productions > b.productions : a.lastSeen > b.lastSeen
        }
    }

    /// La faute à surveiller en conversation : le point le plus fréquent, s'il revient
    /// dans deux productions au moins. Jamais l'orthographe : l'oral ne voit pas les
    /// accents (Whisper transcrit juste, le récapitulatif oral les ignore).
    var watch: Pattern? {
        mostFrequent.first { $0.productions >= Self.watchThreshold && $0.category != .spelling }
    }

    /// Les accents écrits reviennent : la consigne de l'écrit le rappelle.
    var spellingRecurs: Bool { spellingProductions >= Self.spellingThreshold }
}
