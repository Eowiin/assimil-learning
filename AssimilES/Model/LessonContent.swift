import Foundation

/// Ce qu'une activité peut montrer, et pourquoi quand elle ne le peut pas.
///
/// Trois absences à ne jamais confondre : une activité **absente par conception**
/// (une révision hebdomadaire n'a pas d'exercices), un contenu **pas encore importé**
/// (le livre n'est saisi que pour quelques leçons) et un contenu **mal saisi** (un
/// gabarit illisible). Les deux dernières renvoient au livre ; la première ne
/// demande rien.
enum ActivityContent: Equatable {
    case notApplicable
    case available
    /// Une partie existe — l'énoncé, l'audio — mais pas tout.
    case partial(String)
    case notImported(String)
    case unreadable(String)

    var needsBook: Bool {
        switch self {
        case .partial, .notImported, .unreadable: true
        case .available, .notApplicable: false
        }
    }

    var notice: String? {
        switch self {
        case .partial(let message), .notImported(let message), .unreadable(let message): message
        case .available, .notApplicable: nil
        }
    }
}

/// Une phrase qu'on cherche avant d'afficher la réponse.
struct RevealItem: Identifiable, Hashable {
    let n: Int
    let prompt: String?
    let answer: String?
    let clip: AudioClip?
    var id: Int { n }
}

enum LessonContent {

    // MARK: - Compréhension

    static func comprehension(_ text: LessonText?) -> ActivityContent {
        guard let text, !text.sentences.isEmpty else {
            return .notImported("Texte pas encore importé : l'audio fonctionne, lis la leçon dans le livre.")
        }
        let translated = text.sentences.allSatisfy { !($0.fr ?? "").isEmpty }
        return translated
            ? .available
            : .partial("Traduction, prononciation figurée et notes pas encore importées : lis-les dans le livre.")
    }

    /// La synthèse grammaticale d'une révision hebdomadaire.
    static func reviewSummary(_ lesson: Lesson, _ text: LessonText?) -> ActivityContent {
        guard lesson.isReview else { return .notApplicable }
        guard let review = text?.review else {
            return .notImported("La synthèse de révision n'est pas encore importée : lis-la dans le livre.")
        }
        return review.sections.isEmpty ? .unreadable("Synthèse de révision vide : lis-la dans le livre.") : .available
    }

    // MARK: - Exercice 1 : traduire

    /// Livre : « Ejercicio 1 – Traduzca / Exercice 1 – Traduisez ». L'énoncé est en
    /// espagnol — c'est aussi ce que dit l'audio — et le corrigé en français.
    static func translationItems(_ lesson: Lesson, _ text: LessonText?) -> [RevealItem] {
        let numbers = Set(lesson.exercise.compactMap(\.n)).union(text?.exercise.map(\.n) ?? [])
        return numbers.sorted().map { n in
            let sentence = text?.exerciseSentence(n)
            return RevealItem(n: n,
                              prompt: nonEmpty(sentence?.es),
                              answer: nonEmpty(sentence?.fr),
                              clip: lesson.exercise.first { $0.n == n })
        }
    }

    static func translation(_ lesson: Lesson, _ text: LessonText?) -> ActivityContent {
        guard !lesson.isReview else { return .notApplicable }
        let items = translationItems(lesson, text)
        guard !items.isEmpty else {
            return .notImported("L'exercice 1 n'est pas encore importé : fais-le dans le livre.")
        }
        if items.contains(where: { $0.answer == nil }) {
            return .partial("Corrigé pas encore importé : traduis à voix haute, puis vérifie dans le livre.")
        }
        if items.contains(where: { $0.prompt == nil }) {
            return .partial("Énoncé écrit pas encore importé : écoute-le, le corrigé est là.")
        }
        return .available
    }

    // MARK: - Exercice 2 : compléter

    static func completion(_ lesson: Lesson, _ text: LessonText?) -> ActivityContent {
        guard !lesson.isReview else { return .notApplicable }
        guard let exercise = text?.exercise2 else {
            return .notImported("L'exercice 2 n'est pas encore importé : fais-le dans le livre.")
        }
        if let problem = exercise.problems.first {
            return .unreadable("L'exercice 2 est mal saisi (\(problem)) : fais-le dans le livre.")
        }
        return .available
    }

    // MARK: - Deuxième vague

    /// Restituer l'espagnol à partir du français, réponse cachée.
    static func waveItems(_ lesson: Lesson, _ text: LessonText?) -> [RevealItem] {
        lesson.dialogue.compactMap { clip in
            guard let n = clip.n else { return nil }
            let sentence = text?.sentence(n)
            return RevealItem(n: n, prompt: nonEmpty(sentence?.fr), answer: nonEmpty(sentence?.es), clip: clip)
        }
    }

    static func secondWave(_ lesson: Lesson, _ text: LessonText?) -> ActivityContent {
        let items = waveItems(lesson, text)
        guard !items.isEmpty else {
            return .notImported("Leçon \(lesson.number) introuvable : fais la deuxième vague dans le livre.")
        }
        if items.contains(where: { $0.prompt == nil }) {
            return .partial("Traduction française de la leçon \(lesson.number) pas encore importée : "
                            + "fais la restitution dans le livre, espagnol caché.")
        }
        return .available
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
