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

struct LessonText: Decodable, Hashable {
    let number: Int
    let titleES: String?
    let titleFR: String?
    let sentences: [SentenceText]
    let exercise: [SentenceText]
    /// « audio » quand l'espagnol vient de la transcription des enregistrements et
    /// non du livre : les mots sont fiables, la ponctuation est approchée et il n'y
    /// a ni traduction, ni prononciation figurée, ni notes.
    let source: String?

    func sentence(_ n: Int) -> SentenceText? { sentences.first { $0.n == n } }
    func exerciseSentence(_ n: Int) -> SentenceText? { exercise.first { $0.n == n } }

    /// Le texte espagnol seul suffit à lire en écoutant, mais pas au thème inversé,
    /// qui part du français. Sans ce distinguo, le mode s'affichait disponible dès
    /// qu'un fichier texte existait et ne produisait aucune étape.
    var hasTranslation: Bool { sentences.contains { !($0.fr ?? "").isEmpty } }
}

enum LessonTextStore {
    private static var cache: [Int: LessonText?] = [:]

    /// `nil` quand la leçon n'a pas encore été saisie — cas normal et attendu.
    static func text(for lessonNumber: Int) -> LessonText? {
        if let cached = cache[lessonNumber] { return cached }

        let name = String(format: "L%03d", lessonNumber)
        let loaded: LessonText? = Bundle.main
            .url(forResource: name, withExtension: "json", subdirectory: "text")
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
