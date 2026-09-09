import Foundation

/// Un mot de la référence, et s'il est passé à la reconnaissance.
struct WordVerdict: Identifiable, Hashable {
    let id: Int
    let word: String
    let isUnderstood: Bool
}

/// La comparaison entre ce qui était à dire et ce que la machine a entendu.
///
/// C'est **la même règle que le pipeline** (`tools/verify-clips.py`) : on replie le
/// texte sur ses lettres et ses chiffres — minuscules, sans accents, sans
/// ponctuation **et sans espaces** — puis on compare caractère par caractère.
///
/// Sans les espaces, ce n'est pas un détail de forme : une plaque rendue `XH553`
/// puis `XH 553` est le même contenu réécrit autrement, et un découpage en mots la
/// comptait pour deux mots perdus. Trois des cinq premières alertes du pipeline
/// étaient de cette nature. On compare donc les caractères, et on ne remonte aux
/// mots que pour l'affichage.
enum SpanishMatch {

    /// Le texte réduit à ses lettres et ses chiffres, avec la position d'origine
    /// de chaque caractère conservée en regard — c'est elle qui permet de
    /// remonter du diff au mot qu'il désigne.
    static func fold(_ text: String) -> (folded: [Character], origin: [String.Index]) {
        var folded: [Character] = []
        var origin: [String.Index] = []

        var i = text.startIndex
        while i < text.endIndex {
            let decomposed = String(text[i]).lowercased().decomposedStringWithCanonicalMapping
            for scalar in decomposed.unicodeScalars {
                // Les accents partent avec les marques combinantes : « está » et
                // « esta » sont le même mot pour qui écoute.
                guard scalar.properties.generalCategory != .nonspacingMark,
                      CharacterSet.alphanumerics.contains(scalar)
                else { continue }
                folded.append(Character(scalar))
                origin.append(i)
            }
            i = text.index(after: i)
        }
        return (folded, origin)
    }

    /// Les mots de la référence, chacun dit passé ou non.
    static func compare(reference: String, heard: String) -> [WordVerdict] {
        let ref = fold(reference)
        let spoken = fold(heard).folded

        // Ce que la référence contient et que la reconnaissance n'a pas rendu.
        var missing = Set<Int>()
        for change in spoken.difference(from: ref.folded) {
            if case let .remove(offset, _, _) = change { missing.insert(offset) }
        }

        return words(in: reference).enumerated().map { index, range in
            let positions = ref.origin.indices.filter { range.contains(ref.origin[$0]) }
            // Un mot sans lettre ni chiffre — un tiret de dialogue — n'est pas un
            // mot à dire : il ne peut pas être manqué.
            guard !positions.isEmpty else {
                return WordVerdict(id: index, word: String(reference[range]), isUnderstood: true)
            }
            let lost = positions.filter(missing.contains).count
            // Le mot est passé tant que la majorité de ses lettres l'a été : la
            // reconnaissance hésite sur une voyelle sans que le mot soit perdu.
            return WordVerdict(id: index,
                               word: String(reference[range]),
                               isUnderstood: lost * 2 <= positions.count)
        }
    }

    /// Vrai quand les deux textes disent la même chose, ponctuation, accents et
    /// espaces ignorés.
    static func isIdentical(_ a: String, _ b: String) -> Bool {
        fold(a).folded == fold(b).folded
    }

    private static func words(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                if let s = start { ranges.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i = text.index(after: i)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }
}
