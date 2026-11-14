import Foundation

/// Ce que le partenaire de conversation reçoit de l'apprenant (`docs/module-profil.md`,
/// étape 3) : la faute qui revient, et des mots compris mais pas encore dits. Calculé
/// sur l'iPhone à l'ouverture, envoyé à chaque requête : le serveur ne garde rien.
struct ConversationProfile: Codable, Equatable, Sendable {
    /// La faute qui revient le plus, nommée comme l'IA l'a nommée.
    var watch: String?
    /// Des mots compris en révision, pas encore retrouvés depuis le français.
    var words: [String] = []

    /// Une consigne courte garde l'IA rapide et concentrée.
    static let maxWords = 5

    var isEmpty: Bool { watch == nil && words.isEmpty }

    /// Nil quand il n'y a rien à dire : le partenaire garde sa consigne d'avant.
    ///
    /// - La faute : le point le plus fréquent, s'il revient dans deux conversations
    ///   au moins. Une faute isolée n'est pas encore « la faute qui revient ».
    /// - Les mots : la carte `recognize` est connue, la carte `recall` ne l'est pas
    ///   encore (ou n'existe pas). Les plus récemment révisés d'abord : ils sont frais.
    static func make(patterns: ErrorPatterns, cards: [Card], calendar: Calendar = .current) -> ConversationProfile? {
        let watch = patterns.mostFrequent.first { $0.conversations >= 2 }?.tag
        let byItem = Dictionary(grouping: cards.filter(\.isActive), by: \.itemID)
        let words = byItem.values
            .compactMap { cards -> (lemma: String, reviewed: Date)? in
                guard let recognize = cards.first(where: { $0.angle == Card.Angle.recognize }),
                      let item = recognize.vocabItem, recognize.isKnown(calendar: calendar),
                      !(cards.first(where: { $0.angle == Card.Angle.recall })?.isKnown(calendar: calendar) ?? false)
                else { return nil }
                return (item.lemma, recognize.lastReviewedAt ?? .distantPast)
            }
            .sorted { $0.reviewed != $1.reviewed ? $0.reviewed > $1.reviewed : $0.lemma < $1.lemma }
            .prefix(maxWords)
            .map(\.lemma)
        let profile = ConversationProfile(watch: watch, words: Array(words))
        return profile.isEmpty ? nil : profile
    }
}
