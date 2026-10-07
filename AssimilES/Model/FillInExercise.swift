import Foundation

/// Le deuxième exercice du livre : « Ejercicio 2 – Complete / Exercice 2 – Complétez ».
///
/// Le livre donne la phrase française, puis l'espagnol amputé de quelques mots —
/// « chaque point représente une lettre ou un caractère » — et son corrigé ne liste
/// que les mots manquants. Le JSON garde la phrase espagnole **entière**, les trous
/// entre crochets, les variantes admises séparées par `|` :
///
///     "exercise2": {
///       "items": [{ "n": 2, "fr": "Je vais bien, merci.", "es": "[Estoy] bien, [gracias]." }]
///     }
///
/// La première variante est celle du livre : elle donne la longueur des pointillés
/// et c'est elle que la correction affiche. Les suivantes ne servent qu'à ne pas
/// refuser une réponse que le livre admet aussi — elles se saisissent depuis le
/// livre, elles ne se devinent pas.
struct FillInExercise: Decodable, Hashable {
    /// Consigne imprimée, quand elle diffère de « Complete ».
    let instruction: String?
    let items: [FillInItem]

    init(instruction: String?, items: [FillInItem]) {
        self.instruction = instruction
        self.items = items
    }

    /// Ce qui rend l'exercice inutilisable dans l'app. Une seule phrase mal saisie
    /// suffit : mieux vaut renvoyer au livre que proposer un exercice à moitié juste.
    var problems: [String] {
        if items.isEmpty { return ["aucune phrase"] }
        return items.compactMap { item in item.problem.map { "phrase \(item.n) : \($0)" } }
    }
}

struct FillInBlank: Hashable {
    let index: Int
    /// Réponses admises, celle du livre en premier.
    let answers: [String]

    var expected: String { answers.first ?? "" }
}

struct FillInItem: Decodable, Hashable, Identifiable {
    enum Segment: Hashable {
        case text(String)
        case blank(FillInBlank)
    }

    let n: Int
    let fr: String?
    let template: String
    let segments: [Segment]
    /// Pourquoi le gabarit n'a pas pu être lu, le cas échéant.
    let problem: String?

    var id: Int { n }

    var blanks: [FillInBlank] {
        segments.compactMap { if case .blank(let blank) = $0 { blank } else { nil } }
    }

    /// La phrase complète, telle que le corrigé la rétablit.
    var solution: String {
        segments.map {
            switch $0 {
            case .text(let text): text
            case .blank(let blank): blank.expected
            }
        }.joined()
    }

    init(n: Int, fr: String?, template: String) {
        self.n = n
        self.fr = fr
        self.template = template
        switch FillInTemplate.parse(template) {
        case .success(let segments):
            self.segments = segments
            self.problem = nil
        case .failure(let error):
            self.segments = []
            self.problem = error.description
        }
    }

    private enum CodingKeys: String, CodingKey { case n, fr, es }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(n: try c.decode(Int.self, forKey: .n),
                  fr: try c.decodeIfPresent(String.self, forKey: .fr),
                  template: try c.decodeIfPresent(String.self, forKey: .es) ?? "")
    }
}

enum FillInTemplateError: Error, Equatable, CustomStringConvertible {
    case empty
    case noBlank
    case unclosed
    case unopened
    case nested
    case emptyAnswer

    var description: String {
        switch self {
        case .empty: "gabarit vide"
        case .noBlank: "aucun trou entre crochets"
        case .unclosed: "crochet ouvert jamais fermé"
        case .unopened: "crochet fermé jamais ouvert"
        case .nested: "crochets imbriqués"
        case .emptyAnswer: "trou sans réponse"
        }
    }
}

enum FillInTemplate {
    /// Découpe un gabarit en texte imprimé et trous. Aucune réparation : un gabarit
    /// douteux est signalé, pas deviné.
    static func parse(_ template: String) -> Result<[FillInItem.Segment], FillInTemplateError> {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.empty)
        }
        var segments: [FillInItem.Segment] = []
        var text = ""
        var blank: String?
        var count = 0

        for character in template {
            switch character {
            case "[":
                guard blank == nil else { return .failure(.nested) }
                if !text.isEmpty { segments.append(.text(text)); text = "" }
                blank = ""
            case "]":
                guard let content = blank else { return .failure(.unopened) }
                let answers = content.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard !answers.contains(where: \.isEmpty) else { return .failure(.emptyAnswer) }
                segments.append(.blank(FillInBlank(index: count, answers: answers)))
                count += 1
                blank = nil
            default:
                if blank != nil { blank?.append(character) } else { text.append(character) }
            }
        }
        guard blank == nil else { return .failure(.unclosed) }
        if !text.isEmpty { segments.append(.text(text)) }
        guard count > 0 else { return .failure(.noBlank) }
        return .success(segments)
    }
}

/// Le verdict sur un trou.
enum BlankVerdict: Equatable {
    case empty
    case correct
    /// Accepté : seule la casse diffère. La majuscule d'un mot tient à sa place dans
    /// la phrase, que le gabarit imprime déjà ; la correction montre la forme du livre.
    case acceptedIgnoringCase(expected: String)
    /// Refusé : en espagnol l'accent distingue des mots (tú/tu, él/el, sí/si, qué/que)
    /// et le ñ n'est pas un n. On dit seulement que c'est l'accent, sans donner la réponse.
    case accentMismatch
    case incorrect

    var isAccepted: Bool {
        switch self {
        case .correct, .acceptedIgnoringCase: true
        default: false
        }
    }
}

/// La politique de correction, en une place.
///
/// - **Espaces** : ignorés en tête et en fin, les suites réduites à une espace.
/// - **Ponctuation** : non évaluée. Elle est imprimée autour du trou ; `¿Y tú?` saisi
///   dans le trou de `¿[Y tú]?` est la bonne réponse.
/// - **Majuscules** : non exigées, mais signalées avec la forme du livre.
/// - **Accents et ñ** : exigés. Une réponse juste à l'accent près est refusée, avec
///   un indice qui ne donne pas la réponse.
/// - **Variantes** : seules celles saisies dans le gabarit sont admises.
/// - **Plusieurs trous** : chacun est jugé seul ; la phrase est réussie quand tous
///   sont acceptés.
enum FillInGrader {
    static let spanish = Locale(identifier: "es_ES")

    static func normalize(_ text: String) -> String {
        let characters = text.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> Character in
            CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
                ? " " : Character(scalar)
        }
        return String(characters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func grade(_ typed: String, against blank: FillInBlank) -> BlankVerdict {
        let answer = normalize(typed)
        guard !answer.isEmpty else { return .empty }

        var best = BlankVerdict.incorrect
        for variant in blank.answers {
            let expected = normalize(variant)
            if answer == expected { return .correct }
            if answer.lowercased(with: spanish) == expected.lowercased(with: spanish) {
                best = .acceptedIgnoringCase(expected: variant)
            } else if best == .incorrect, fold(answer) == fold(expected) {
                best = .accentMismatch
            }
        }
        return best
    }

    static func grade(_ typed: [String], item: FillInItem) -> [BlankVerdict] {
        item.blanks.map { blank in
            grade(typed.indices.contains(blank.index) ? typed[blank.index] : "", against: blank)
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: spanish)
    }
}

/// Où en est une phrase à compléter. Sauvegardé dans l'avancement de la séance.
struct FillInAttempt: Codable, Equatable {
    var typed: [String] = []
    /// Vérifications depuis la dernière correction affichée : c'est ce qui dit s'il
    /// y a un verdict à montrer.
    var checks = 0
    var solved = false
    /// La correction a été affichée : la phrase compte comme travaillée, et peut
    /// encore être retapée pour s'en assurer.
    var revealed = false

    var isDone: Bool { solved || revealed }

    /// Affiche la correction. Le verdict d'avant ne vaut plus : la phrase est faite,
    /// et redire « corrige les autres » à côté de la réponse du livre contredirait
    /// l'écran. Ce qui a été tapé reste, pour le comparer ou le retaper.
    mutating func reveal() {
        revealed = true
        checks = 0
    }

    @discardableResult
    mutating func check(_ answers: [String], item: FillInItem) -> [BlankVerdict] {
        typed = answers
        checks += 1
        let verdicts = FillInGrader.grade(answers, item: item)
        if !verdicts.isEmpty, verdicts.allSatisfy(\.isAccepted) { solved = true }
        return verdicts
    }
}
