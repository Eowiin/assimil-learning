import Foundation
import Testing
@testable import AssimilES

/// Un hasard rejouable : le même germe donne toujours le même tirage.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("Prononciation : les sons repérés à l'orthographe")
struct SpanishTargetTests {

    @Test("θ : z, ce, ci")
    func theta() {
        #expect(PronunciationDrill.targets(in: "La cena") == [.theta])
        #expect(PronunciationDrill.targets(in: "Cinco") == [.theta])
        #expect(PronunciationDrill.targets(in: "Azul") == [.theta])
        // « ca », « co » se disent [k].
        #expect(PronunciationDrill.targets(in: "Casa, cosa") == [])
    }

    @Test("Jota : j, ge, gi ; pas gue, gui")
    func jota() {
        #expect(PronunciationDrill.targets(in: "La gente") == [.jota])
        #expect(PronunciationDrill.targets(in: "Jamón") == [.jota])
        #expect(PronunciationDrill.targets(in: "Gigante") == [.jota])
        #expect(PronunciationDrill.targets(in: "Sigue la guía") == [])
    }

    @Test("r et rr, v ; le b écrit ne compte pas")
    func rAndV() {
        #expect(PronunciationDrill.targets(in: "El perro") == [.r])
        #expect(PronunciationDrill.targets(in: "Un vaso") == [.v])
        #expect(PronunciationDrill.targets(in: "Bueno, bien") == [])
    }

    @Test("Accents et majuscules ne changent rien, et deux mots ne se lient pas")
    func folding() {
        #expect(PronunciationDrill.targets(in: "¡CÉNIT!") == [.theta])
        // Le « c » de « tic » et le « e » de « el » sont dans deux mots.
        #expect(PronunciationDrill.targets(in: "tic el") == [])
    }

    @Test("Un tiret de dialogue n'est pas un mot")
    func wordCount() {
        #expect(PronunciationDrill.wordCount("– ¡Hola, Laura! ¿Qué tal?") == 4)
    }
}

@Suite("Prononciation : les phrases d'une séance")
struct PronunciationDrillTests {

    private let manifest = Fixture.manifest(lessonCount: 10, sentences: 4)

    private func text(_ number: Int, _ sentences: [String]) -> LessonText {
        let items = sentences.enumerated().map { i, es in
            #"{"n": \#(i + 1), "es": "\#(es)"}"#
        }
        return try! Fixture.text(#"{"number": \#(number), "sentences": [\#(items.joined(separator: ","))]}"#)
    }

    private var texts: [Int: LessonText] {
        [
            1: text(1, ["Hola.",                                    // trop courte
                        "¿Dónde está la gente de Jaén?",            // jota
                        "Quiero un vaso de vino, por favor.",       // r, v
                        "Las cinco amigas cenan en la plaza."]),    // θ
            2: text(2, ["Mi perro se llama Ramón y vive aquí.",     // r, v
                        "Es una ciudad muy bonita y muy tranquila hoy, con su playa, su puerto y sus calles.",  // trop longue
                        "¿Dónde está la gente de Jaén?",            // déjà vue en leçon 1
                        "Hay un hotel en la calle mayor."]),        // r
            // Leçon 3 : pas de texte importé.
        ]
    }

    private func candidates(_ lessons: Set<Int>) -> [DrillSentence] {
        PronunciationDrill.candidates(lessons: lessons, manifest: manifest) { texts[$0] }
    }

    @Test("Le dialogue des leçons vues, de 4 à 12 mots, avec un son à travailler")
    func candidatesFiltered() {
        let found = candidates([1, 2, 3])
        #expect(found.map(\.id) == ["1-2", "1-3", "1-4", "2-1", "2-4"])
        #expect(found.first?.targets == [.jota])
        #expect(found[1].targets == [.r, .v])
        #expect(found[1].clip.file == "S03.m4a")
    }

    @Test("Les leçons non vues ne donnent rien")
    func onlySeenLessons() {
        #expect(candidates([2]).map(\.id) == ["2-1", "2-3", "2-4"])
        #expect(candidates([]).isEmpty)
    }

    @Test("Une phrase sans voix du natif est écartée")
    func needsNativeClip() {
        let short = Fixture.manifest(lessonCount: 10, sentences: 2)
        let found = PronunciationDrill.candidates(lessons: [1], manifest: short) { texts[$0] }
        #expect(found.map(\.id) == ["1-2"])
    }

    @Test("Cinq phrases, qui couvrent d'abord chacun des sons")
    func pickCoversTargets() {
        let pool = candidates([1, 2])
        for seed in 0..<20 {
            var generator = SeededGenerator(state: UInt64(seed))
            let picked = PronunciationDrill.pick(from: pool, count: 3, using: &generator)
            #expect(picked.count == 3)
            #expect(Set(picked.map(\.id)).count == 3)
            // θ n'est que dans 1-4, la jota que dans 1-2 : elles sont toujours prises.
            #expect(picked.contains { $0.id == "1-4" })
            #expect(picked.contains { $0.id == "1-2" })
        }
    }

    @Test("Moins de candidates que de places : toutes, une seule fois")
    func pickFewer() {
        var generator = SeededGenerator(state: 7)
        let picked = PronunciationDrill.pick(from: candidates([1, 2]), using: &generator)
        #expect(Set(picked.map(\.id)) == ["1-2", "1-3", "1-4", "2-1", "2-4"])
    }

    @Test("Le même germe, le même tirage")
    func deterministic() {
        var a = SeededGenerator(state: 42), b = SeededGenerator(state: 42)
        let pool = candidates([1, 2])
        #expect(PronunciationDrill.pick(from: pool, count: 2, using: &a).map(\.id)
                == PronunciationDrill.pick(from: pool, count: 2, using: &b).map(\.id))
    }

    @Test("Au tout début du parcours, la première leçon")
    func firstDay() {
        #expect(PronunciationDrill.lessons(available: []) == [1])
        #expect(PronunciationDrill.lessons(available: [1, 2]) == [1, 2])
    }
}
