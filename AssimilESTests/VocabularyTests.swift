import Foundation
import Testing
@testable import AssimilES

@Suite("Vocabulaire du paquet")
struct VocabularyTests {

    private func write(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent(Vocabulary.fileName))
        return dir
    }

    @Test("Un mot a un identifiant canonique, et seul celui-là se relit")
    func canonicalItem() throws {
        let item = try #require(VocabItem(lemma: "estar"))
        #expect(item.itemID().rawValue == "assimil-es:V:estar")
        #expect(VocabItem(item.itemID()) == item)
        #expect(Card.makeKey(item: item.itemID(), angle: Card.Angle.recognize) == "assimil-es:V:estar#recognize")

        #expect(VocabItem(lemma: "Estar") == nil)
        #expect(VocabItem(lemma: "") == nil)
        #expect(VocabItem(lemma: "a:b") == nil)
        #expect(VocabItem(lemma: "a#b") == nil)
        #expect(VocabItem(lemma: "dos palabras") == nil)
        // « á » décomposé (a + accent) n'est pas la forme canonique de « á ».
        #expect(VocabItem(lemma: "ma\u{0301}s") == nil)
        #expect(VocabItem(lemma: "más") != nil)
        // Une phrase n'est pas un mot, et inversement.
        #expect(VocabItem(try #require(ItemID("assimil-es:L012:S04"))) == nil)
        #expect(AssimilItem(item.itemID()) == nil)
    }

    @Test("La forme canonique d'un mot quelconque")
    func canonicalForm() {
        #expect(VocabItem.canonical("Fatal.") == "fatal")
        #expect(VocabItem.canonical("¡Hola!") == "hola")
        #expect(VocabItem.canonical("ma\u{0301}s") == "más")
        #expect(VocabItem.canonical("...") == nil)
    }

    @Test("Lecture de vocab.json : mots, occurrences, renommages")
    func load() throws {
        let dir = try write("""
            {"version": 1,
             "words": [
               {"lemma": "estar", "forms": ["estoy", "está"], "translation": "être",
                "firstLesson": 1, "count": 6,
                "occurrences": [{"lesson": 1, "isExercise": false, "n": 2},
                                {"lesson": 3, "isExercise": true, "n": 1}]},
               {"lemma": "Mal", "forms": ["mal"], "translation": null,
                "firstLesson": 2, "count": 1, "occurrences": []}
             ],
             "renamed": {"barrar": "barrer"}}
            """)
        let vocabulary = try #require(Vocabulary.load(from: dir))
        // Le mot à la forme non canonique est écarté, pas fatal.
        #expect(vocabulary.words.map(\.lemma) == ["estar"])
        let item = try #require(VocabItem(lemma: "estar"))
        let estar = try #require(vocabulary.word(item))
        #expect(estar.translation == "être")
        #expect(estar.occurrences.map(\.item) == [AssimilItem(lesson: 1, isExercise: false, number: 2),
                                                  AssimilItem(lesson: 3, isExercise: true, number: 1)])
        #expect(vocabulary.renamed == ["barrar": "barrer"])
    }

    @Test("Sans vocab.json, ou illisible : pas de vocabulaire, pas d'erreur")
    func missingOrBroken() throws {
        #expect(Vocabulary.load(from: nil) == nil)
        #expect(Vocabulary.load(from: FileManager.default.temporaryDirectory.appendingPathComponent("absent")) == nil)
        #expect(Vocabulary.load(from: try write("{ pas du json")) == nil)
        // `renamed` est facultatif.
        #expect(Vocabulary.load(from: try write(#"{"version": 1, "words": []}"#))?.renamed == [:])
    }
}
