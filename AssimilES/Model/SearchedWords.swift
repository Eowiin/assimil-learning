import Foundation
import SwiftData

/// Les mots cherchés en conversation (étape 6c) : ceux qu'un débutant a dits en
/// français ou demandés (« Je ne sais pas le dire »). Chacun devient une carte du
/// lexique (`lexique-es`), comme un mot du texte du bloc 2 : recto la phrase de l'IA qui
/// l'a donné, le mot en gras ; verso sa traduction.
enum SearchedWords {
    /// La source d'un mot entré dans l'état parce qu'il a été cherché.
    static let source = "searched"

    /// Inscrire les mots cherchés. Un mot inconnu de l'état y entre « vu », avec la
    /// source `searched`. Un mot déjà là sans phrase la reçoit, et garde sa source. Un mot
    /// qui a déjà sa phrase (donc sa carte) ne change pas : sa carte ne change pas de recto.
    /// Sans phrase de l'IA, le recto est l'espagnol seul et le verso le français dit.
    static func record(_ words: [SearchedWord], language: String, ranks: [String: Int],
                       at date: Date, in context: ModelContext) throws {
        guard !words.isEmpty else { return }
        var existing = Dictionary(
            try context.fetch(FetchDescriptor<LexemeState>()).filter { $0.language == language }.map { ($0.lemma, $0) },
            uniquingKeysWith: { first, _ in first })
        for word in words {
            guard let lemma = VocabItem.canonical(word.lemma), VocabItem(lemma: lemma) != nil else { continue }
            let state = existing[lemma] ?? {
                let created = LexemeState(language: language, lemma: lemma, rank: ranks[lemma], source: source, at: date)
                context.insert(created)
                existing[lemma] = created
                return created
            }()
            let card = Self.card(of: word, lemma: lemma)
            state.recordSeen(sentence: card.sentence, form: card.form, translation: card.translation)
        }
    }

    /// Le recto, la forme à mettre en gras et le verso d'un mot cherché.
    static func card(of word: SearchedWord, lemma: String) -> (sentence: String, form: String?, translation: String) {
        let es = word.es.trimmingCharacters(in: .whitespaces)
        if let sentence = word.sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty,
           let translation = word.sentenceFR?.trimmingCharacters(in: .whitespaces), !translation.isEmpty {
            // La forme dite par l'IA, si elle est dans la phrase ; sinon le lemme, s'il y est.
            let form = [es, lemma].first { AbsorptionText.range(of: $0, in: sentence) != nil }
            return (sentence, form, translation)
        }
        return (es, es, word.fr.trimmingCharacters(in: .whitespaces))
    }
}
