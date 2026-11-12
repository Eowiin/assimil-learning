import Foundation

/// Un mot ou une expression à apprendre, désigné par sa forme de base :
/// « assimil-es:V:estar », « assimil-es:V:qué tal ».
///
/// Comme `AssimilItem` pour les phrases, il écrit et lit le chemin de son
/// identifiant, et seule la forme canonique passe : minuscules, Unicode composé
/// (NFC), sans « : » ni « # » — ils séparent le paquet et l'angle dans les clés de
/// carte —, les mots d'une expression séparés par une seule espace. Sans cela,
/// `Estar` et `estar`, ou `qué  tal` et `qué tal`, feraient deux cartes.
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

    /// La forme canonique d'un mot ou d'une expression quelconque, ou nil s'il n'en
    /// reste rien.
    static func canonical(_ word: String) -> String? {
        let cleaned = word.lowercased().precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return isCanonical(cleaned) ? cleaned : nil
    }

    var isExpression: Bool { lemma.contains(" ") }

    static func isCanonical(_ lemma: String) -> Bool {
        !lemma.isEmpty
            && lemma == lemma.lowercased()
            // Par scalaires : `==` sur des `String` tient « á » et « a + ◌́ » pour égaux,
            // alors que les clés de carte, elles, diffèrent octet par octet.
            && lemma.unicodeScalars.elementsEqual(lemma.precomposedStringWithCanonicalMapping.unicodeScalars)
            && !lemma.contains(where: { $0 == ":" || $0 == "#" || ($0.isWhitespace && $0 != " ") })
            && !lemma.hasPrefix(" ") && !lemma.hasSuffix(" ") && !lemma.contains("  ")
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
    /// Traduction automatique des phrases d'exemple que le livre ne traduit pas, par
    /// chemin de phrase (« L012:S04 ») : le livre n'a le français que des leçons 1 à 5.
    let sentences: [String: String]
    /// La place de chaque mot dans `words` : un accueil qui compte ses cartes dues ne
    /// parcourt pas deux mille mots par carte.
    private let index: [String: Int]

    private enum CodingKeys: String, CodingKey { case version, words, renamed, sentences }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        // Un mot dont la forme n'est pas canonique serait une carte impossible à
        // retrouver : il est écarté à la lecture, pas fatal.
        words = try c.decode([Word].self, forKey: .words).filter { $0.item != nil }
        renamed = try c.decodeIfPresent([String: String].self, forKey: .renamed) ?? [:]
        sentences = try c.decodeIfPresent([String: String].self, forKey: .sentences) ?? [:]
        index = Dictionary(words.enumerated().map { ($1.lemma, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func word(_ item: VocabItem) -> Word? { index[item.lemma].map { words[$0] } }

    /// La traduction automatique d'une phrase, quand le livre n'en donne pas.
    func sentenceTranslation(_ item: AssimilItem) -> String? { sentences[item.path] }

    static let fileName = "vocab.json"

    /// `nil` quand le paquet n'a pas (encore) de vocabulaire : un cas normal.
    static func load(from textDirectory: URL?) -> Vocabulary? {
        guard let url = textDirectory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Vocabulary.self, from: data)
    }
}

/// Le vocabulaire en cours, lu une fois. Il vient du même dossier que le texte des
/// leçons (`LessonTextStore.directory`) : le paquet trouvé au lancement, ou les
/// textes fictifs des tests d'interface (`ASSIMIL_TEXT_DIR`). 500 Ko de JSON ne se
/// relisent pas à chaque affichage de l'accueil.
@MainActor
enum VocabularyStore {
    private static var cache: (directory: URL?, vocabulary: Vocabulary?)?

    static var current: Vocabulary? {
        let directory = LessonTextStore.directory
            ?? Bundle.main.resourceURL?.appendingPathComponent("text", isDirectory: true)
        if let cache, cache.directory == directory { return cache.vocabulary }
        let vocabulary = Vocabulary.load(from: directory)
        cache = (directory, vocabulary)
        return vocabulary
    }
}
