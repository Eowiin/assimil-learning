import Foundation
import Testing
@testable import AssimilES

@Suite("Exercice 2 : gabarits et correction")
struct FillInTests {

    private func item(_ template: String) -> FillInItem {
        FillInItem(n: 1, fr: "Phrase fictive.", template: template)
    }

    @Test("Plusieurs trous, variantes, texte imprimé conservé")
    func parsing() throws {
        let sentence = item("¿[Vives|Vive] en [Lugo]?")
        #expect(sentence.problem == nil)
        #expect(sentence.blanks.count == 2)
        #expect(sentence.blanks[0].answers == ["Vives", "Vive"])
        #expect(sentence.blanks[1].expected == "Lugo")
        #expect(sentence.solution == "¿Vives en Lugo?")
    }

    @Test("Un gabarit mal formé est signalé, pas réparé",
          arguments: [("", FillInTemplateError.empty),
                      ("Sin huecos.", .noBlank),
                      ("[abierto", .unclosed),
                      ("cerrado]", .unopened),
                      ("[a [b]]", .nested),
                      ("[uno|]", .emptyAnswer)])
    func malformed(template: String, error: FillInTemplateError) {
        #expect(item(template).problem == error.description)
    }

    @Test("Politique : accents exigés, casse et ponctuation non notées")
    func grading() {
        let blank = FillInBlank(index: 0, answers: ["Tú"])
        #expect(FillInGrader.grade("Tú", against: blank) == .correct)
        #expect(FillInGrader.grade("  tú ", against: blank) == .acceptedIgnoringCase(expected: "Tú"))
        #expect(FillInGrader.grade("¿Tú?", against: blank) == .correct)
        #expect(FillInGrader.grade("tu", against: blank) == .accentMismatch)
        #expect(FillInGrader.grade("yo", against: blank) == .incorrect)
        #expect(FillInGrader.grade(" ", against: blank) == .empty)

        let tilde = FillInBlank(index: 0, answers: ["año"])
        #expect(FillInGrader.grade("ano", against: tilde) == .accentMismatch)
        #expect(!FillInGrader.grade("ano", against: tilde).isAccepted)

        let words = FillInBlank(index: 0, answers: ["qué tal"])
        #expect(FillInGrader.grade("qué   tal", against: words) == .correct)
        #expect(FillInGrader.grade("quetal", against: words) == .incorrect)

        let variants = FillInBlank(index: 0, answers: ["vale", "de acuerdo"])
        #expect(FillInGrader.grade("De acuerdo", against: variants).isAccepted)
        #expect(FillInGrader.grade("claro", against: variants) == .incorrect)
    }

    @Test("Chaque trou est jugé seul ; la phrase est réussie quand tous le sont")
    func multipleBlanksAndRetry() {
        let sentence = item("[Estoy] bien, [gracias].")
        var attempt = FillInAttempt()

        let first = attempt.check(["Estoy", "grasias"], item: sentence)
        #expect(first == [.correct, .incorrect])
        #expect(!attempt.solved)
        #expect(!attempt.isDone)

        let second = attempt.check(["estoy", "gracias"], item: sentence)
        #expect(second.allSatisfy { $0.isAccepted })
        #expect(attempt.solved)
        #expect(attempt.checks == 2)

        var revealed = FillInAttempt()
        revealed.revealed = true
        #expect(revealed.isDone)
        #expect(FillInGrader.grade(["Estoy"], item: sentence) == [.correct, .empty])
    }
}

@Suite("Textes : compatibilité et contenus absents")
struct LessonTextTests {
    let manifest = Fixture.manifest()

    /// La forme des fichiers saisis depuis le livre, avant l'exercice 2.
    static let bookJSON = """
    {
      "number": 12,
      "titleES": "Título ficticio",
      "titleFR": "Titre fictif",
      "sentences": [
        { "n": 1, "es": "Frase uno.", "fr": "Phrase un.", "pron": "frassé ouno", "note": "Note fictive." },
        { "n": 2, "es": "Frase dos.", "fr": "Phrase deux.", "pron": "frassé doss", "note": null },
        { "n": 3, "es": "Frase tres.", "fr": "Phrase trois.", "pron": null, "note": null }
      ],
      "exercise": [
        { "n": 1, "es": "Ejercicio uno.", "fr": "Exercice un.", "pron": null, "note": null },
        { "n": 2, "es": "Ejercicio dos.", "fr": "Exercice deux.", "pron": null, "note": null }
      ]
    }
    """

    /// La forme des fichiers issus de la transcription de l'audio.
    static let audioJSON = """
    { "number": 12, "source": "audio", "titleES": "Título.",
      "sentences": [{ "n": 1, "es": "Frase uno." }, { "n": 2, "es": "Frase dos." }, { "n": 3, "es": "Frase tres." }],
      "exercise": [{ "n": 1, "es": "Ejercicio uno." }, { "n": 2, "es": "Ejercicio dos." }] }
    """

    @Test("Les anciens fichiers se lisent sans exercice 2 ni synthèse")
    func legacyFiles() throws {
        let book = try Fixture.text(Self.bookJSON)
        #expect(book.sentences.count == 3)
        #expect(book.exercise2 == nil)
        #expect(book.review == nil)
        #expect(book.hasTranslation)

        let audio = try Fixture.text(Self.audioJSON)
        #expect(audio.source == "audio")
        #expect(!audio.hasTranslation)

        let bare = try Fixture.text(#"{ "number": 3, "sentences": [] }"#)
        #expect(bare.exercise.isEmpty)
        #expect(try Fixture.text(#"{ "number": 3, "exercise2": null }"#).exercise2 == nil)
    }

    @Test("Un exercice 2 mal formé n'emporte pas la leçon")
    func malformedExercise2() throws {
        let text = try Fixture.text(#"{ "number": 12, "sentences": [{ "n": 1, "es": "Uno." }], "exercise2": { "items": "cassé" } }"#)
        #expect(text.sentences.count == 1)
        let lesson = try #require(manifest.lesson(12))
        guard case .unreadable = LessonContent.completion(lesson, text) else {
            Issue.record("exercice illisible attendu"); return
        }
    }

    @Test("Absent par conception ≠ pas encore importé")
    func absenceKinds() throws {
        let review = try #require(manifest.lesson(7))
        let ordinary = try #require(manifest.lesson(12))
        let book = try Fixture.text(Self.bookJSON)

        #expect(LessonContent.translation(review, nil) == .notApplicable)
        #expect(LessonContent.completion(review, nil) == .notApplicable)
        guard case .notImported = LessonContent.reviewSummary(review, nil) else {
            Issue.record("synthèse non importée attendue"); return
        }
        #expect(LessonContent.reviewSummary(ordinary, book) == .notApplicable)

        #expect(LessonContent.translation(ordinary, book) == .available)
        guard case .notImported = LessonContent.completion(ordinary, book) else {
            Issue.record("exercice 2 non importé attendu"); return
        }
        #expect(LessonContent.completion(ordinary, book).needsBook)
    }

    @Test("Énoncé sans corrigé, audio sans texte : partiel, renvoi au livre")
    func partialContent() throws {
        let lesson = try #require(manifest.lesson(12))
        let audio = try Fixture.text(Self.audioJSON)

        guard case .partial = LessonContent.translation(lesson, audio) else { Issue.record("partiel attendu"); return }
        let items = LessonContent.translationItems(lesson, nil)
        #expect(items.map(\.n) == [1, 2])
        #expect(items.allSatisfy { $0.clip != nil && $0.prompt == nil && $0.answer == nil })
        guard case .partial = LessonContent.translation(lesson, nil) else { Issue.record("partiel attendu"); return }
        guard case .notImported = LessonContent.comprehension(nil) else { Issue.record("non importé attendu"); return }
        guard case .partial = LessonContent.comprehension(audio) else { Issue.record("partiel attendu"); return }
    }

    @Test("Exercice 2 importé, et deuxième vague selon la traduction disponible")
    func availableContent() throws {
        let lesson = try #require(manifest.lesson(12))
        let json = Self.bookJSON.dropLast(2) + #", "exercise2": { "items": [{ "n": 1, "fr": "Je vis ici.", "es": "[Vivo] aquí." }] } }"#
        let text = try Fixture.text(String(json))
        #expect(LessonContent.completion(lesson, text) == .available)
        #expect(text.exercise2?.items.first?.solution == "Vivo aquí.")

        #expect(LessonContent.secondWave(lesson, text) == .available)
        let wave = LessonContent.waveItems(lesson, text)
        #expect(wave.first?.prompt == "Phrase un.")
        #expect(wave.first?.answer == "Frase uno.")
        guard case .partial = LessonContent.secondWave(lesson, try Fixture.text(Self.audioJSON)) else {
            Issue.record("vague partielle attendue sans traduction"); return
        }
    }
}
