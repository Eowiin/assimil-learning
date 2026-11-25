import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Séance adaptative : le bloc Absorption")
@MainActor
struct AbsorptionTests {

    static let pack = VocabularyTestTests.pack

    static let json = #"""
    {"text": "Fui a la cumbre. Llevaba la mochila. Hacía frío.",
     "sentences": [{"es": "Fui a la cumbre.", "fr": "Je suis allé au sommet."},
                   {"es": "Llevaba la mochila y madrugué.", "fr": "Je portais le sac et je me suis levé tôt."},
                   {"es": "Hacía frío.", "fr": "Il faisait froid."}],
     "coverage": 0.97, "unknown_lemmas": ["frío"], "new_used": ["cumbre", "mochila", "madrugar"],
     "objective_hits": [1], "attempts": 1,
     "new_occurrences": [{"lemma": "madrugar", "sentence": 1, "form": "madrugué"}]}
    """#

    static func text(_ json: String = json) throws -> AbsorptionText {
        try JSONDecoder().decode(AbsorptionText.self, from: Data(json.utf8))
    }

    static func session(in context: ModelContext, lemmas: [String] = ["cumbre", "mochila", "madrugar"]) -> StudySession {
        let session = StudySession(language: "es", day: Fixture.date(day: 2), objectiveID: pack.objectives.first?.id,
                                   startedAt: Fixture.date(day: 2), calendar: Fixture.calendar)
        session.newLemmas = lemmas
        session.theme = pack.themes.first?.id
        context.insert(session)
        return session
    }

    // MARK: - Le texte

    @Test("Le texte se lit, avec ou sans new_occurrences ; une phrase sans place se cherche dans le texte")
    func decoding() throws {
        let text = try Self.text()
        #expect(text.isObjectiveHit(1) && !text.isObjectiveHit(0))
        // madrugar vient du serveur ; cumbre et mochila sont cherchés tels quels.
        #expect(text.occurrences.map(\.lemma) == ["madrugar", "cumbre", "mochila"])
        #expect(text.occurrences.map(\.sentence) == [1, 0, 1])
        #expect(text.newForms == ["cumbre", "madrugué", "mochila"])

        var object = try #require(try JSONSerialization.jsonObject(with: Data(Self.json.utf8)) as? [String: Any])
        object["new_occurrences"] = nil
        let older = try JSONDecoder().decode(AbsorptionText.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.newOccurrences == nil)
        // Sans le serveur, un verbe conjugué reste sans phrase.
        #expect(older.occurrences.map(\.lemma) == ["cumbre", "mochila"])
    }

    @Test("Un mot entier, sans la casse : « mar » n'est pas dans « mariposa »")
    func wordRanges() {
        let sentence = "Mar y mariposa, el mar."
        let ranges = AbsorptionText.ranges(of: ["mar"], in: sentence)
        #expect(ranges.map { String(sentence[$0]) } == ["Mar", "mar"])
        #expect(AbsorptionText.range(of: "mar", in: "La mariposa") == nil)
        let bold = AbsorptionBlockContent.highlighted("Llevaba la mochila.", forms: ["mochila"])
        #expect(String(bold.characters) == "Llevaba la mochila.")
        #expect(bold.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test("La requête : niveau de l'apprenant, thème en espagnol, lemmes connus, mots du jour")
    func request() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        _ = try DailyPlannerTests.placed(in: context)
        let session = Self.session(in: context)
        let request = try Absorption.request(for: session, pack: Self.pack, in: context).get()
        let objective = try #require(Self.pack.objectives.first)
        // L'objectif de la séance est A0, l'apprenant B1 : le texte est à son niveau (5b).
        #expect(request.level == "B1" && objective.level == "A0")
        #expect(request.theme == Self.pack.themes.first?.es)
        #expect(request.objective.id == objective.id)
        #expect(request.newLemmas == ["cumbre", "mochila", "madrugar"])
        #expect(request.targetWords == Absorption.targetWords)
        #expect(request.knownLemmas.count >= 500)

        session.objectiveID = nil
        guard case .failure = Absorption.request(for: session, pack: Self.pack, in: context) else {
            Issue.record("Sans objectif, pas de texte")
            return
        }
    }

    // MARK: - Les mots vus

    @Test("Les mots employés passent vus avec leur phrase, une fois ; un mot oublié par l'IA reste inconnu")
    func markSeen() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = Self.session(in: context, lemmas: ["cumbre", "mochila", "madrugar", "sendero"])
        let text = try Self.text()
        Absorption.markSeen(text, in: session, ranks: ["cumbre": 3000], at: Fixture.date(day: 2), in: context)
        Absorption.markSeen(text, in: session, ranks: [:], at: Fixture.date(day: 2, hour: 11), in: context)

        let states = try context.fetch(FetchDescriptor<LexemeState>(sortBy: [SortDescriptor(\.lemma)]))
        #expect(states.map(\.lemma) == ["cumbre", "madrugar", "mochila"])
        #expect(states.allSatisfy { $0.status == LexemeState.Status.seen && $0.seenCount == 1 })
        #expect(states.allSatisfy { $0.source == LexiconWords.source })
        let madrugar = try #require(states.first { $0.lemma == "madrugar" })
        #expect(madrugar.contextES == "Llevaba la mochila y madrugué.")
        #expect(madrugar.contextForm == "madrugué")
        #expect(madrugar.contextFR == "Je portais le sac et je me suis levé tôt.")
        #expect(states.first?.rank == 3000)

        // Revu un autre jour, le mot garde sa première phrase.
        madrugar.recordSeen(sentence: "Madrugué otra vez.", form: "madrugué", translation: "fr")
        #expect(madrugar.contextES == "Llevaba la mochila y madrugué." && madrugar.seenCount == 2)
    }

    // MARK: - Les cartes

    static func lexicon(_ lemmas: [String]) -> LexiconWords {
        LexiconWords(words: lemmas.map { .init(lemma: $0, sentence: "Una \($0).", form: $0, translation: "Un \($0).") })
    }

    @Test("Les mots du texte passent devant ceux d'Assimil, sous le même plafond, une carte recognize chacun")
    func newCardsFromLexicon() throws {
        let vocabulary = try VocabStudyTests().vocabulary(lessons: 1)
        let lexicon = Self.lexicon(["cumbre", "mochila"])
        let new = VocabStudy.newCards(vocabulary: vocabulary, lessons: [1], cards: [], limit: 3, lexicon: lexicon)
        #expect(new.map(\.item.lemma) == ["cumbre", "mochila", "mot1x1"])
        #expect(new.map(\.isLexicon) == [true, true, false])
        #expect(new[0].key == "lexique-es:V:cumbre#recognize")
        #expect(VocabStudy.newCards(vocabulary: vocabulary, lessons: [1], cards: [], limit: 1, lexicon: lexicon)
            .map(\.item.lemma) == ["cumbre"])
    }

    @Test("Une carte du lexique est due comme les autres ; sans sa phrase, elle est orpheline ; « mot1x1 » d'Assimil reste à part")
    func dueLexiconCards() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let vocabulary = try VocabStudyTests().vocabulary(lessons: 1)
        let created = Fixture.date(day: 1)
        let lexiconCard = VocabStudy.introduce(.init(item: try #require(VocabItem(lemma: "cumbre")),
                                                     angle: Card.Angle.recognize, pack: VocabStudy.lexiconPack),
                                               at: created, in: context)
        CardReview.grade(lexiconCard, .easy, at: created, in: context)
        // Le même lemme qu'un mot d'Assimil, dans le paquet du lexique, sans phrase connue.
        let homonym = VocabStudy.introduce(.init(item: try #require(VocabItem(lemma: "mot1x1")),
                                                 angle: Card.Angle.recognize, pack: VocabStudy.lexiconPack),
                                           at: created, in: context)
        CardReview.grade(homonym, .easy, at: created, in: context)
        let cards = try context.fetch(FetchDescriptor<Card>())
        let later = Fixture.date(day: 60)

        #expect(VocabStudy.due(cards, in: vocabulary, lexicon: Self.lexicon(["cumbre"]), now: later)
            .map(\.key) == ["lexique-es:V:cumbre#recognize"])
        #expect(VocabStudy.due(cards, in: vocabulary, now: later).isEmpty)

        // Retirer le mot du lexique ne touche pas au mot d'Assimil.
        var session = VocabSession(due: [lexiconCard], new: [.init(item: try #require(VocabItem(lemma: "cumbre")),
                                                                     angle: Card.Angle.recognize)])
        session.drop(try #require(VocabItem(lemma: "cumbre")), pack: VocabStudy.lexiconPack)
        #expect(session.remaining == 1)
    }

    @Test("Une carte recognize connue rend le mot reconnu ; une carte recall connue, actif")
    func knowledgeRaisesLexeme() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let state = LexemeState(language: "es", lemma: "cumbre", rank: 3000, source: LexiconWords.source,
                                at: Fixture.date(day: 1))
        context.insert(state)
        let card = VocabStudy.introduce(.init(item: try #require(VocabItem(lemma: "cumbre")),
                                              angle: Card.Angle.recognize, pack: VocabStudy.lexiconPack),
                                        at: Fixture.date(day: 1), in: context)
        CardReview.grade(card, .good, at: Fixture.date(day: 1), in: context)
        VocabStudy.noteKnowledge(of: card, ranks: [:], at: Fixture.date(day: 1), calendar: Fixture.calendar, in: context)
        // Notée le jour même : pas encore connue.
        #expect(state.status == LexemeState.Status.seen)

        CardReview.grade(card, .good, at: Fixture.date(day: 1, hour: 10), in: context)
        CardReview.grade(card, .good, at: Fixture.date(day: 4), in: context)
        VocabStudy.noteKnowledge(of: card, ranks: [:], at: Fixture.date(day: 4), calendar: Fixture.calendar, in: context)
        #expect(state.status == LexemeState.Status.recognized)

        // Un mot d'Assimil absent de l'état y entre.
        let recall = VocabStudy.introduce(.init(item: try #require(VocabItem(lemma: "hablar")), angle: Card.Angle.recall),
                                          at: Fixture.date(day: 1), in: context)
        CardReview.grade(recall, .good, at: Fixture.date(day: 1), in: context)
        CardReview.grade(recall, .good, at: Fixture.date(day: 1, hour: 10), in: context)
        CardReview.grade(recall, .good, at: Fixture.date(day: 4), in: context)
        VocabStudy.noteKnowledge(of: recall, ranks: ["hablar": 40], at: Fixture.date(day: 4),
                                 calendar: Fixture.calendar, in: context)
        let hablar = try #require(try context.fetch(FetchDescriptor<LexemeState>()).first { $0.lemma == "hablar" })
        #expect(hablar.status == LexemeState.Status.active && hablar.rank == 40)
        #expect(hablar.source == LexiconMigration.source)
    }

    // MARK: - La préparation

    final class Service: AbsorptionService, @unchecked Sendable {
        var failVoiceAfter: Int?
        var spoken = 0
        let text: AbsorptionText
        init(text: AbsorptionText) { self.text = text }

        func generate(_ request: AbsorptionRequest) async throws -> AbsorptionText { text }

        func speak(_ sentences: [String]) async throws -> [Data] {
            if let limit = failVoiceAfter, spoken >= limit { throw ServerError.network("PC éteint") }
            spoken += sentences.count
            return sentences.map { Data($0.utf8) }
        }
    }

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "absorption-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func wait(_ preparer: AbsorptionPreparer) async {
        for _ in 0..<200 where preparer.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Le texte est gardé dans la séance, la voix sur le disque par paquets ; la voix ratée garde le texte")
    func preparation() async throws {
        let container = try Fixture.container()
        let context = container.mainContext
        _ = try DailyPlannerTests.placed(in: context)
        let session = Self.session(in: context)
        let sentences = (0..<7).map { AbsorptionText.Sentence(es: "Frase \($0).", fr: "Phrase \($0).") }
        let text = AbsorptionText(text: "", sentences: sentences, coverage: 1, unknownLemmas: [], newUsed: [],
                                  objectiveHits: nil, attempts: 1, newOccurrences: nil)
        let service = Service(text: text)
        service.failVoiceAfter = 5
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        // La voix d'une autre séance part.
        try AbsorptionAudio.write(Data(), sessionKey: "es:2026-09-01", sentence: 0, root: root)

        let voiceRoot = Self.root()
        defer { try? FileManager.default.removeItem(at: voiceRoot) }
        let preparer = AbsorptionPreparer(root: root, voiceRoot: voiceRoot)
        preparer.prepare(session, pack: Self.pack, service: service, in: context)
        await Self.wait(preparer)
        #expect(Absorption.text(of: session) == text)
        #expect(preparer.phase(for: session) == .voiceFailed("PC éteint"))
        #expect(AbsorptionAudio.missing(sessionKey: session.key, count: 7, root: root) == [5, 6])
        #expect(!FileManager.default.fileExists(atPath: AbsorptionAudio.folder(for: "es:2026-09-01", root: root).path))

        // On réessaie : seules les phrases sans voix repartent.
        service.failVoiceAfter = nil
        preparer.prepare(session, pack: Self.pack, service: service, in: context)
        await Self.wait(preparer)
        #expect(preparer.phase(for: session) == .ready)
        #expect(service.spoken == 7)
        let url = try #require(preparer.audioURL(for: session, sentence: 6))
        #expect(try Data(contentsOf: url) == Data("Frase 6.".utf8))
        #expect(AbsorptionPreparer(root: root).phase(for: session) == .ready)
        // Chaque phrase dite est aussi dans le cache du bloc 1 (étape 5c).
        let cached = try #require(VoiceCache.cached("Frase 6.", root: voiceRoot))
        #expect(try Data(contentsOf: cached) == Data("Frase 6.".utf8))
    }
}
