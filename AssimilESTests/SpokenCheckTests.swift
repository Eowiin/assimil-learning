import Foundation
import Testing
@testable import AssimilES

@Suite("Réponses dites : comparaison à la réponse attendue")
struct SpokenCheckTests {

    @Test("Identique malgré ponctuation, majuscules, accents et apostrophes")
    func identical() {
        #expect(SpokenCheck.compare(heard: "comment tu t'appelles", expected: "Comment tu t'appelles ?").isIdentical)
        #expect(SpokenCheck.compare(heard: "ca va bien", expected: "Ça va bien.").isIdentical)
        #expect(SpokenCheck.compare(heard: "Hola que tal", expected: "¡Hola! ¿Qué tal?").isIdentical)
    }

    @Test("Un mot manquant ou en trop : pas identique, et le manquant est désigné")
    func different() throws {
        let missing = SpokenCheck.compare(heard: "je vais bien", expected: "Je vais bien, merci.")
        #expect(!missing.isIdentical)
        let merci = try #require(missing.words.last)
        #expect(merci.word.hasPrefix("merci"))
        #expect(!merci.isUnderstood)
        #expect(missing.words.dropLast().allSatisfy { $0.isUnderstood })

        let extra = SpokenCheck.compare(heard: "oui je vais très bien merci", expected: "Je vais bien, merci.")
        #expect(!extra.isIdentical)
        #expect(extra.words.allSatisfy { $0.isUnderstood })
    }

    @Test("Une autre traduction, juste, n'est pas déclarée identique : l'app ne juge pas le sens")
    func paraphraseIsNotJudged() {
        #expect(!SpokenCheck.compare(heard: "comment tu vas", expected: "Comment vas-tu ?").isIdentical)
    }

    @Test("« prêt/prête » : les deux formes du livre sont admises")
    func slashVariants() {
        #expect(SpokenCheck.references("Je suis prêt/prête à partir.") == ["Je suis prêt à partir.", "Je suis prête à partir."])
        #expect(SpokenCheck.compare(heard: "je suis prête à partir", expected: "Je suis prêt/prête à partir.").isIdentical)
        #expect(SpokenCheck.compare(heard: "je suis prêt à partir", expected: "Je suis prêt/prête à partir.").isIdentical)
        #expect(!SpokenCheck.compare(heard: "je suis prêt prête à partir", expected: "Je suis prêt/prête à partir.").isIdentical)
        #expect(SpokenCheck.references("Sans alternative.") == ["Sans alternative."])
        #expect(SpokenCheck.references("un/une et le/la").count == 4)
    }

    @Test("Avec des chiffres, la comparaison ne tranche pas")
    func digits() {
        #expect(!SpokenCheck.isJudgeable("Termino a las 7:00."))
        #expect(SpokenCheck.isJudgeable("Termino a las siete."))
    }

    @Test("Un avancement enregistré avant la réponse au micro se relit")
    func legacyRevealState() throws {
        let json = #"{"revealed":true,"outcome":"knew"}"#
        let state = try JSONDecoder().decode(RevealState.self, from: Data(json.utf8))
        #expect(state.outcome == .knew)
        #expect(state.heard == nil)
        #expect(state.identical == nil)

        var spoken = state
        spoken.heard = "hola"
        spoken.identical = false
        let roundTrip = try JSONDecoder().decode(RevealState.self, from: JSONEncoder().encode(spoken))
        #expect(roundTrip == spoken)
    }
}
