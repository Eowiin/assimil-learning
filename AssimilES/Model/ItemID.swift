import Foundation

/// L'identifiant global d'un élément de contenu : « assimil-es:L012:S04 ».
///
/// C'est par lui que l'état de l'apprenant (cartes, journal) désigne le contenu,
/// qui reste dans les paquets. Deux règles :
///
/// - **Pas de version.** Un paquet corrigé ou réimporté garde ses identifiants :
///   sinon chaque mise à jour du contenu orphelinerait l'historique.
/// - **Une seule écriture par élément.** L'identifiant sert de clé unique en
///   chaîne ; « L12 » et « L012 » feraient deux cartes pour une même phrase. Seule
///   la forme canonique est acceptée à l'analyse.
///
/// Le chemin après le paquet appartient au paquet : ce type ne le lit pas. Pour
/// Assimil, c'est `AssimilItem` qui le construit et l'analyse.
struct ItemID: Hashable, Comparable, CustomStringConvertible {
    let pack: String
    let path: String

    init(pack: String, path: String) {
        self.pack = pack
        self.path = path
    }

    /// Le paquet va jusqu'au premier « : ». Il ne contient que des minuscules, des
    /// chiffres et des tirets : c'est un nom de dossier, et il préfixe toutes les
    /// clés.
    init?(_ raw: String) {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let pack = String(raw[..<colon])
        let path = String(raw[raw.index(after: colon)...])
        guard Self.isValidPack(pack), !path.isEmpty else { return nil }
        self.init(pack: pack, path: path)
    }

    var rawValue: String { "\(pack):\(path)" }
    var description: String { rawValue }

    static func < (a: ItemID, b: ItemID) -> Bool { a.rawValue < b.rawValue }

    static func isValidPack(_ pack: String) -> Bool {
        !pack.isEmpty && pack.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }
}

/// Une phrase d'Assimil : du dialogue (« S ») ou de l'exercice de traduction (« T »),
/// les lettres des fichiers audio. Propre à Assimil, comme le chemin qu'elle écrit.
struct AssimilItem: Hashable {
    let lesson: Int
    let isExercise: Bool
    let number: Int

    /// « L012:S04 ». Trois chiffres pour la leçon, deux pour la phrase : l'ordre
    /// alphabétique des clés suit alors l'ordre du livre.
    var path: String {
        String(format: "L%03d:%@%02d", lesson, isExercise ? "T" : "S", number)
    }

    func itemID(pack: String = PackStore.assimilSpanishID) -> ItemID {
        ItemID(pack: pack, path: path)
    }

    init(lesson: Int, isExercise: Bool, number: Int) {
        self.lesson = lesson
        self.isExercise = isExercise
        self.number = number
    }

    /// Lit le chemin d'un identifiant. Seule la forme canonique passe : on relit
    /// les nombres, on réécrit, et l'écriture doit retomber sur l'original.
    init?(_ id: ItemID) {
        let parts = id.path.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].first == "L", let lesson = Int(parts[0].dropFirst()),
              let kind = parts[1].first, kind == "S" || kind == "T",
              let number = Int(parts[1].dropFirst()),
              lesson > 0, number > 0
        else { return nil }
        self.init(lesson: lesson, isExercise: kind == "T", number: number)
        guard path == id.path else { return nil }
    }

    /// La clé de `DifficultSentence` (« L012-S04 »), pour la copie vers les cartes.
    init?(legacyKey: String) {
        guard let id = ItemID("\(PackStore.assimilSpanishID):\(legacyKey.replacingOccurrences(of: "-", with: ":"))")
        else { return nil }
        self.init(id)
    }
}
