import Foundation

/// Ce qui change entre la phrase dite et la phrase corrigée, mot à mot, pour le
/// mettre en couleur dans le récapitulatif.
///
/// Les mots se comparent sans casse, sans ponctuation et sans accents écrits : la
/// phrase dite vient de la transcription de Whisper, dont la ponctuation et les
/// accents ne sont pas ceux de l'apprenant. Seul un vrai changement de mot ressort.
enum WordDiff {

    struct Word: Equatable {
        let text: String
        /// Absent de l'autre phrase : retiré de la phrase dite, ou ajouté dans la corrigée.
        let changed: Bool
    }

    static func compare(said: String, corrected: String) -> (said: [Word], corrected: [Word]) {
        let a = words(said), b = words(corrected)
        let keyA = a.map(key), keyB = b.map(key)
        let common = longestCommon(keyA, keyB)
        return (mark(a, kept: common.left), mark(b, kept: common.right))
    }

    /// Les deux phrases disent les mêmes mots, à la casse, la ponctuation et aux
    /// accents écrits près.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        keys(a) == keys(b)
    }

    private static func keys(_ sentence: String) -> [String] {
        words(sentence).map(key).filter { !$0.isEmpty }
    }

    private static func words(_ sentence: String) -> [String] {
        sentence.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func key(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func mark(_ words: [String], kept: Set<Int>) -> [Word] {
        words.enumerated().map { Word(text: $1, changed: !kept.contains($0)) }
    }

    /// La plus longue sous-suite commune (programmation dynamique) : les indices
    /// gardés de part et d'autre. Les phrases sont courtes, le coût quadratique
    /// ne se voit pas.
    private static func longestCommon(_ a: [String], _ b: [String]) -> (left: Set<Int>, right: Set<Int>) {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var left = Set<Int>(), right = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                left.insert(i); right.insert(j)
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (left, right)
    }
}
