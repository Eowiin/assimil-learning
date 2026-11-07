import Foundation

/// Un mot à apprendre, désigné par sa forme de base : « assimil-es:V:estar ».
///
/// Comme `AssimilItem` pour les phrases, il écrit et lit le chemin de son
/// identifiant, et seule la forme canonique passe : minuscules, Unicode composé
/// (NFC), sans espace ni « : » ni « # » — ces deux-là séparent le paquet et l'angle
/// dans les clés de carte. Sans cela, `Estar` et `estar` feraient deux cartes.
struct VocabItem: Hashable {
    let lemma: String

    var path: String { "V:\(lemma)" }

    func itemID(pack: String = PackStore.assimilSpanishID) -> ItemID {
        ItemID(pack: pack, path: path)
    }

    /// Nil si la forme n'est pas canonique.
    init?(lemma: String) {
        guard Self.isCanonical(lemma) else { return nil }
        self.lemma = lemma
    }

    init?(_ id: ItemID) {
        guard id.path.hasPrefix("V:") else { return nil }
        self.init(lemma: String(id.path.dropFirst(2)))
    }

    /// La forme canonique d'un mot quelconque, ou nil s'il n'en reste rien.
    static func canonical(_ word: String) -> String? {
        let cleaned = word.lowercased().precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return isCanonical(cleaned) ? cleaned : nil
    }

    static func isCanonical(_ lemma: String) -> Bool {
        !lemma.isEmpty
            && lemma == lemma.lowercased()
            // Par scalaires : `==` sur des `String` tient « á » et « a + ◌́ » pour égaux,
            // alors que les clés de carte, elles, diffèrent octet par octet.
            && lemma.unicodeScalars.elementsEqual(lemma.precomposedStringWithCanonicalMapping.unicodeScalars)
            && !lemma.contains(where: { $0 == ":" || $0 == "#" || $0.isWhitespace })
    }
}

/// Le vocabulaire d'un paquet, calculé sur le Mac (`tools/vocabulaire/build-vocab.swift`)
/// et rangé dans `text/vocab.json`. L'iPhone ne découpe ni ne traduit rien : il lit.
///
/// Les mots arrivent dans l'ordre où le livre les apporte (première leçon, puis
/// fréquence) : c'est l'ordre des nouvelles cartes.
struct Vocabulary: Decodable, Equatable {
    struct Word: Decodable, Equatable {
        let lemma: String
        /// Les formes rencontrées dans les leçons (« estoy », « está »…).
        let forms: [String]
        /// Traduction d'Apple, corrigée à la main s'il le fallait. Elle aide ; c'est
        /// la phrase de la leçon qui donne le sens.
        let translation: String?
        let firstLesson: Int
        let count: Int
        /// Les phrases où le mot apparaît, dans l'ordre du livre : le contexte et
        /// l'audio du verso.
        let occurrences: [Occurrence]

        var item: VocabItem? { VocabItem(lemma: lemma) }
    }

    struct Occurrence: Decodable, Equatable {
        let lesson: Int
        let isExercise: Bool
        let n: Int

        var item: AssimilItem { AssimilItem(lesson: lesson, isExercise: isExercise, number: n) }
    }

    let version: Int
    let words: [Word]
    /// Formes de base corrigées depuis une génération précédente : « barrar » →
    /// « barrer ». Une carte posée sur l'ancienne forme se déplace sur la nouvelle,
    /// au lieu de rester orpheline.
    let renamed: [String: String]

    private enum CodingKeys: String, CodingKey { case version, words, renamed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        // Un mot dont la forme n'est pas canonique serait une carte impossible à
        // retrouver : il est écarté à la lecture, pas fatal.
        words = try c.decode([Word].self, forKey: .words).filter { $0.item != nil }
        renamed = try c.decodeIfPresent([String: String].self, forKey: .renamed) ?? [:]
    }

    func word(_ item: VocabItem) -> Word? { words.first { $0.lemma == item.lemma } }

    static let fileName = "vocab.json"

    /// `nil` quand le paquet n'a pas (encore) de vocabulaire : un cas normal.
    static func load(from textDirectory: URL?) -> Vocabulary? {
        guard let url = textDirectory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Vocabulary.self, from: data)
    }
}

extension ContentPack {
    var vocabulary: Vocabulary? { Vocabulary.load(from: textDirectory) }
}
