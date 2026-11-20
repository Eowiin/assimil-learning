import Foundation

/// Ce que le partenaire de conversation reçoit de l'apprenant (`docs/module-profil.md`,
/// étape 3) : la faute qui revient, et des mots compris mais pas encore dits. Calculé
/// sur l'iPhone à l'ouverture, envoyé à chaque requête : le serveur ne garde rien.
struct ConversationProfile: Codable, Equatable, Sendable {
    /// La faute qui revient le plus, nommée comme l'IA l'a nommée.
    var watch: String?
    /// Des mots compris en révision, pas encore retrouvés depuis le français.
    var words: [String] = []
    /// Le niveau de l'apprenant (« B1 ») : l'IA parle à sa mesure.
    var level: String?
    /// L'objectif du jour, que l'IA provoque, et que le récapitulatif juge.
    var objective: ConversationObjective?
    /// `roleplay` (le scénario de l'objectif) ou `speed` (questions en rafale). Nil :
    /// la conversation libre.
    var mode: String?
    /// Les lemmes que l'apprenant connaît : le serveur mesure chaque réplique, et la
    /// réécrit plus simple si elle en sort trop. Jamais dans la consigne.
    var allowedLemmas: [String] = []

    init(watch: String? = nil, words: [String] = [], level: String? = nil, objective: ConversationObjective? = nil,
         mode: String? = nil, allowedLemmas: [String] = []) {
        self.watch = watch
        self.words = words
        self.level = level
        self.objective = objective
        self.mode = mode
        self.allowedLemmas = allowedLemmas
    }

    private enum CodingKeys: String, CodingKey {
        case watch, words, level, objective, mode, allowedLemmas = "allowed_lemmas"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watch = try c.decodeIfPresent(String.self, forKey: .watch)
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
        level = try c.decodeIfPresent(String.self, forKey: .level)
        objective = try c.decodeIfPresent(ConversationObjective.self, forKey: .objective)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        allowedLemmas = try c.decodeIfPresent([String].self, forKey: .allowedLemmas) ?? []
    }

    /// Ce qui est vide ne part pas : le profil d'avant le moteur reste identique.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(watch, forKey: .watch)
        try c.encode(words, forKey: .words)
        try c.encodeIfPresent(level, forKey: .level)
        try c.encodeIfPresent(objective, forKey: .objective)
        try c.encodeIfPresent(mode, forKey: .mode)
        if !allowedLemmas.isEmpty { try c.encode(allowedLemmas, forKey: .allowedLemmas) }
    }

    /// Une consigne courte garde l'IA rapide et concentrée.
    static let maxWords = 5

    var isEmpty: Bool { watch == nil && words.isEmpty && level == nil && objective == nil && allowedLemmas.isEmpty }

    /// La ligne de l'écran : « Aujourd'hui : ser/estar · aprovechar, quedar con ».
    var summary: String? {
        let parts = [watch, words.isEmpty ? nil : words.joined(separator: ", ")].compactMap { $0 }
        return parts.isEmpty ? nil : "Aujourd'hui : " + parts.joined(separator: " · ")
    }

    /// Nil quand il n'y a rien à dire : le partenaire garde sa consigne d'avant.
    ///
    /// - La faute : le point le plus fréquent, s'il revient dans deux productions
    ///   (conversations ou écrits) au moins, hors orthographe (`ErrorPatterns.watch`).
    ///   Une faute isolée n'est pas encore « la faute qui revient ».
    /// - Les mots : la carte `recognize` est connue, la carte `recall` ne l'est pas
    ///   encore (ou n'existe pas). Les plus récemment révisés d'abord : ils sont frais.
    static func make(patterns: ErrorPatterns, cards: [Card], calendar: Calendar = .current) -> ConversationProfile? {
        let watch = patterns.watch?.tag
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
