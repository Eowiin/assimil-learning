import Foundation

/// Texte d'une leçon, saisi depuis le livre (voir tools/ocr.swift et la phase 1).
///
/// Le contrat JSON est figé même si l'OCR n'a pas encore couvert toutes les leçons :
/// l'app doit rester utilisable en audio seul sur les leçons sans texte, sinon
/// l'avancement de la saisie bloquerait l'usage quotidien.
struct SentenceText: Decodable, Hashable {
    /// Correspond au `n` du clip audio : c'est ce qui apparie texte et son.
    let n: Int
    let es: String
    let fr: String?
    /// Prononciation figurée du livre.
    let pron: String?
    /// Note grammaticale ou culturelle rattachée à cette phrase.
    let note: String?
}

/// La synthèse grammaticale d'une leçon de révision hebdomadaire, telle que le livre
/// la numérote.
struct ReviewSummary: Decodable, Hashable {
    struct Section: Decodable, Hashable {
        let title: String?
        let text: String
    }

    let sections: [Section]
}

struct LessonText: Decodable, Hashable {
    let number: Int
    let titleES: String?
    let titleFR: String?
    let sentences: [SentenceText]
    /// Exercice 1, « Traduzca » : l'espagnol de l'énoncé, le français du corrigé.
    let exercise: [SentenceText]
    /// Exercice 2, « Complete ». `nil` tant qu'il n'est pas importé — ce qui n'est
    /// pas la même chose qu'une leçon de révision, qui n'en a pas.
    let exercise2: FillInExercise?
    let review: ReviewSummary?
    /// « audio » quand l'espagnol vient de la transcription des enregistrements et
    /// non du livre : les mots sont fiables, la ponctuation est approchée et il n'y
    /// a ni traduction, ni prononciation figurée, ni notes.
    let source: String?

    private enum CodingKeys: String, CodingKey {
        case number, titleES, titleFR, sentences, exercise, exercise2, review, source
    }

    /// Les champs ajoutés depuis sont facultatifs : les fichiers existants se lisent
    /// tels quels. Un exercice 2 présent mais mal formé n'emporte pas la leçon avec
    /// lui — il devient un exercice vide, que l'app signale comme mal saisi.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        titleES = try c.decodeIfPresent(String.self, forKey: .titleES)
        titleFR = try c.decodeIfPresent(String.self, forKey: .titleFR)
        sentences = try c.decodeIfPresent([SentenceText].self, forKey: .sentences) ?? []
        exercise = try c.decodeIfPresent([SentenceText].self, forKey: .exercise) ?? []
        if c.contains(.exercise2), (try? c.decodeNil(forKey: .exercise2)) == false {
            exercise2 = (try? c.decode(FillInExercise.self, forKey: .exercise2))
                ?? FillInExercise(instruction: nil, items: [])
        } else {
            exercise2 = nil
        }
        review = try? c.decodeIfPresent(ReviewSummary.self, forKey: .review)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    func sentence(_ n: Int) -> SentenceText? { sentences.first { $0.n == n } }
    func exerciseSentence(_ n: Int) -> SentenceText? { exercise.first { $0.n == n } }

    /// Distingue une leçon saisie depuis le livre d'une leçon seulement transcrite
    /// depuis l'audio : `hasText` est vrai pour les 100, `hasTranslation` seulement
    /// là où le français existe et peut donc se révéler sous la phrase.
    var hasTranslation: Bool { sentences.contains { !($0.fr ?? "").isEmpty } }
}

enum LessonTextStore {
    private static var cache: [Int: LessonText?] = [:]

    /// Dossier des textes. `nil` : ceux du bundle. Remplacé par les tests, et en
    /// Debug par `ASSIMIL_TEXT_DIR` pour tourner sur des données fictives.
    static var directory: URL? = AppEnvironment.textDirectory {
        didSet { cache = [:] }
    }

    /// `nil` quand la leçon n'a pas encore été saisie — cas normal et attendu.
    static func text(for lessonNumber: Int) -> LessonText? {
        if let cached = cache[lessonNumber] { return cached }

        let name = String(format: "L%03d", lessonNumber)
        let url = directory.map { $0.appendingPathComponent("\(name).json") }
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "text")
        let loaded: LessonText? = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(LessonText.self, from: $0) }

        cache[lessonNumber] = loaded
        return loaded
    }

    static func hasText(for lessonNumber: Int) -> Bool { text(for: lessonNumber) != nil }

    static func hasTranslation(for lessonNumber: Int) -> Bool {
        text(for: lessonNumber)?.hasTranslation ?? false
    }
}
