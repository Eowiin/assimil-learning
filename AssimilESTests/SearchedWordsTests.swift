import Foundation
import SwiftData
import Testing
@testable import AssimilES

/// Les mots cherchés en conversation (étape 6c) : le récapitulatif les rend, ils
/// deviennent des cartes du lexique.
@Suite("Les mots cherchés", .serialized)
@MainActor
struct SearchedWordsTests {

    private let cuchillo = SearchedWord(fr: "couteau", es: "el cuchillo", lemma: "cuchillo",
                                        sentence: "Aquí tiene el cuchillo.", sentenceFR: "Voici le couteau.")

    @Test("Le récapitulatif lit les mots cherchés, avec ou sans phrase")
    func decoding() async throws {
        let session = StubProtocol.session(host: "cherches.ts.net") { _ in
            (200, Data(#"{"corrections":[],"searched":[{"fr":"couteau","es":"el cuchillo","lemma":"cuchillo","sentence":"Aquí tiene el cuchillo.","sentence_fr":"Voici le couteau."},{"fr":"fourchette","es":"tenedor","lemma":"tenedor","sentence":null,"sentence_fr":null}]}"#.utf8))
        }
        let client = ConversationClient(baseURL: URL(string: "https://cherches.ts.net")!, session: session)
        let review = try await client.review(history: [ConversationMessage(role: .user, content: "couteau", ask: true)])
        #expect(review.searched == [cuchillo, SearchedWord(fr: "fourchette", es: "tenedor", lemma: "tenedor")])
        // Un serveur d'avant la 6b : pas de champ, pas d'erreur.
        let old = try JSONDecoder().decode(ConversationReview.self, from: Data(#"{"corrections":[]}"#.utf8))
        #expect(old.searched == nil)
    }

    @Test("Un mot inconnu entre « vu », source searched, avec la phrase de l'IA au recto")
    func newWord() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        try SearchedWords.record([cuchillo], language: "es", ranks: ["cuchillo": 2100],
                                 at: Fixture.date(day: 3), in: context)
        let state = try #require(try context.fetch(FetchDescriptor<LexemeState>()).first)
        #expect(state.key == "es:cuchillo" && state.rank == 2100)
        #expect(state.status == LexemeState.Status.seen)
        #expect(state.source == SearchedWords.source)
        #expect(state.contextES == "Aquí tiene el cuchillo.")
        #expect(state.contextForm == "el cuchillo")
        #expect(state.contextFR == "Voici le couteau.")

        // Il devient une carte recognize du lexique, annoncée comme cherchée.
        let lexicon = LexiconWords(states: [state])
        #expect(lexicon.words.first?.searched == true)
        let new = VocabStudy.newCards(vocabulary: try VocabStudyTests().vocabulary(lessons: 1), lessons: [],
                                      cards: [], limit: 5, lexicon: lexicon)
        #expect(new.map(\.key) == ["lexique-es:V:cuchillo#recognize"])
    }

    @Test("Sans phrase de l'IA : l'espagnol au recto, le français dit au verso")
    func withoutSentence() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        try SearchedWords.record([SearchedWord(fr: "fourchette", es: "tenedor", lemma: "Tenedor")],
                                 language: "es", ranks: [:], at: Fixture.date(day: 3), in: context)
        let state = try #require(try context.fetch(FetchDescriptor<LexemeState>()).first)
        #expect(state.lemma == "tenedor")
        #expect(state.contextES == "tenedor" && state.contextForm == "tenedor" && state.contextFR == "fourchette")
    }

    @Test("La forme en gras : celle que l'IA a dite, sinon le lemme, sinon rien")
    func form() {
        let card = { (es: String, sentence: String) in
            SearchedWords.card(of: SearchedWord(fr: "x", es: es, lemma: "jarra", sentence: sentence, sentenceFR: "y"),
                               lemma: "jarra").form
        }
        #expect(card("una jarra de agua", "Se dice «una jarra de agua».") == "una jarra de agua")
        #expect(card("una jarra de agua", "¿Quiere una jarra?") == "jarra")
        #expect(card("una jarra de agua", "¿Quiere agua?") == nil)
    }

    @Test("Un mot qui a déjà sa phrase garde sa carte ; un mot connu sans phrase la reçoit, et garde sa source")
    func existingWords() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let read = LexemeState(language: "es", lemma: "cuchillo", rank: nil, source: LexiconWords.source,
                               at: Fixture.date(day: 1))
        read.recordSeen(sentence: "Corta con el cuchillo.", form: "cuchillo", translation: "Il coupe avec le couteau.")
        let produced = LexemeState(language: "es", lemma: "jarra", rank: nil, source: "conversation",
                                   at: Fixture.date(day: 1))
        produced.raise(to: LexemeState.Status.recognized, at: Fixture.date(day: 1))
        context.insert(read)
        context.insert(produced)
        let jarra = SearchedWord(fr: "carafe", es: "jarra", lemma: "jarra",
                                 sentence: "Una jarra de agua.", sentenceFR: "Une carafe d'eau.")
        try SearchedWords.record([cuchillo, jarra, jarra], language: "es", ranks: [:],
                                 at: Fixture.date(day: 3), in: context)
        let states = try context.fetch(FetchDescriptor<LexemeState>(sortBy: [SortDescriptor(\.lemma)]))
        #expect(states.map(\.lemma) == ["cuchillo", "jarra"])
        #expect(states[0].contextES == "Corta con el cuchillo.")
        #expect(states[1].contextES == "Una jarra de agua." && states[1].source == "conversation")
        // Le statut ne descend jamais.
        #expect(states[1].status == LexemeState.Status.recognized)
    }

    @Test("Le récapitulatif du jeu de rôle inscrit les mots cherchés")
    func sessionRecord() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let pack = try CurriculumPack.load(from: AdaptiveStateTests.packDirectory, language: "es")
        let session = StudySession(language: "es", day: Fixture.date(day: 3), objectiveID: nil,
                                   startedAt: Fixture.date(day: 3))
        context.insert(session)
        try SessionConversation.record(ConversationReview(corrections: [], searched: [cuchillo]), in: session,
                                       pack: pack, at: Fixture.date(day: 3), in: context)
        let states = try context.fetch(FetchDescriptor<LexemeState>())
        #expect(states.map(\.lemma) == ["cuchillo"])
        #expect(states.first?.source == SearchedWords.source)
    }
}
