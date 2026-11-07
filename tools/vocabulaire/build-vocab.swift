// Calcule le vocabulaire des leçons et l'écrit dans le paquet (text/vocab.json).
// Plan : docs/module-vocabulaire.md, étape 1.
//
//   swift tools/vocabulaire/build-vocab.swift [dossier des textes] [corrections]
//   swift tools/vocabulaire/build-vocab.swift Resources/text content/vocab/corrections.json
//
// Par défaut : Resources/text et content/vocab/corrections.json (facultatif). Le
// fichier est écrit à côté des textes, hors dépôt comme eux.
//
// Trois outils d'Apple, tous sur la machine : NaturalLanguage pour découper les mots
// et retrouver leur forme de base, sa classe lexicale pour écarter les mots-outils,
// Translation pour un premier sens en français (langues à installer une fois :
// Réglages Système › Général › Langue et région › Langues de traduction).
// Mesuré sur les 100 leçons (docs/cadrage-app.md) : forme de base juste à ~93 %,
// traduction à ~85-90 %. Le fichier de corrections rattrape le reste :
//
//   {
//     "forms":        { "barran": "barrer" },     une forme rencontrée → sa forme de base
//     "lemmas":       { "gracia": "gracias" },    une forme de base → la bonne
//     "translations": { "pesadilla": "cauchemar" },
//     "excluded":     [ "fa", "pues" ]            mots qui ne feront pas de carte
//   }
//
// Une forme de base corrigée garde la trace de l'ancienne (`renamed`) : une carte déjà
// posée sur l'ancienne se déplace dans l'app au lieu de rester orpheline. Les
// renommages des générations précédentes sont conservés.

import Foundation
import NaturalLanguage
import Translation

struct Sentence: Decodable { let n: Int; let es: String }
struct Lesson: Decodable { let number: Int; let sentences: [Sentence]; let exercise: [Sentence]? }

struct Corrections: Decodable {
    var forms: [String: String] = [:]
    var lemmas: [String: String] = [:]
    var translations: [String: String] = [:]
    var excluded: [String] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forms = try c.decodeIfPresent([String: String].self, forKey: .forms) ?? [:]
        lemmas = try c.decodeIfPresent([String: String].self, forKey: .lemmas) ?? [:]
        translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
    }
    private enum CodingKeys: String, CodingKey { case forms, lemmas, translations, excluded }
}

struct Occurrence: Codable, Hashable, Comparable {
    let lesson: Int, isExercise: Bool, n: Int
    static func < (a: Occurrence, b: Occurrence) -> Bool {
        (a.lesson, a.isExercise ? 1 : 0, a.n) < (b.lesson, b.isExercise ? 1 : 0, b.n)
    }
}

struct Word: Codable {
    let lemma: String
    var forms: [String]
    var translation: String?
    let firstLesson: Int
    var count: Int
    var occurrences: [Occurrence]
}

struct Output: Codable {
    let version: Int
    let words: [Word]
    let renamed: [String: String]
}

/// La même règle que `VocabItem.canonical` dans l'app : minuscules, Unicode composé,
/// sans ponctuation autour, sans espace, « : » ni « # ».
func canonical(_ word: String) -> String? {
    let s = word.lowercased().precomposedStringWithCanonicalMapping
        .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    guard !s.isEmpty, !s.contains(where: { $0 == ":" || $0 == "#" || $0.isWhitespace }) else { return nil }
    return s
}

/// Classes écartées : elles relient les mots, elles ne s'apprennent pas en cartes.
let functionClasses: Set<NLTag> = [.determiner, .preposition, .conjunction, .pronoun,
                                   .particle, .classifier, .idiom, .otherWord]

// MARK: - Entrées

let args = CommandLine.arguments
let textDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources/text")
let correctionsURL = URL(fileURLWithPath: args.count > 2 ? args[2] : "content/vocab/corrections.json")
let outURL = textDir.appendingPathComponent("vocab.json")

var corrections = Corrections()
if let data = try? Data(contentsOf: correctionsURL) {
    corrections = try JSONDecoder().decode(Corrections.self, from: data)
}
let previous = (try? Data(contentsOf: outURL)).flatMap { try? JSONDecoder().decode(Output.self, from: $0) }

var lessons: [Lesson] = []
for n in 1...999 {
    let url = textDir.appendingPathComponent(String(format: "L%03d.json", n))
    guard let data = try? Data(contentsOf: url) else { continue }
    lessons.append(try JSONDecoder().decode(Lesson.self, from: data))
}
guard !lessons.isEmpty else { print("aucune leçon dans \(textDir.path)"); exit(1) }

// MARK: - Mots et formes de base

let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
var words: [String: Word] = [:]
var formsOf: [String: Set<String>] = [:]
var rawToCorrected: [String: String] = [:]
var tokens = 0, correctedTokens = 0

for lesson in lessons {
    let sentences = lesson.sentences.map { ($0, false) } + (lesson.exercise ?? []).map { ($0, true) }
    for (s, isExercise) in sentences {
        let text = s.es
        tagger.string = text
        tagger.setLanguage(.spanish, range: text.startIndex..<text.endIndex)
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            guard let form = canonical(String(text[range])), form.contains(where: \.isLetter) else { return true }
            if functionClasses.contains(tag ?? .otherWord) { return true }
            // Une majuscule hors début de phrase : un prénom, une ville. « ¡Hola » ou
            // « ¿Eres » ouvrent la phrase : seules des lettres avant comptent.
            let startsSentence = !text[..<range.lowerBound].contains(where: \.isLetter)
            if !startsSentence, text[range].first?.isUppercase == true { return true }

            tokens += 1
            let raw = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
                .flatMap { canonical($0.rawValue) } ?? form
            var lemma = corrections.forms[form] ?? raw
            lemma = corrections.lemmas[lemma] ?? lemma
            if lemma != raw { rawToCorrected[raw] = lemma; correctedTokens += 1 }

            let occurrence = Occurrence(lesson: lesson.number, isExercise: isExercise, n: s.n)
            if var w = words[lemma] {
                w.count += 1
                if w.occurrences.last != occurrence { w.occurrences.append(occurrence) }
                words[lemma] = w
            } else {
                words[lemma] = Word(lemma: lemma, forms: [], translation: nil, firstLesson: lesson.number,
                                    count: 1, occurrences: [occurrence])
            }
            formsOf[lemma, default: []].insert(form)
            return true
        }
    }
}

let excluded = Set(corrections.excluded.compactMap(canonical))
for lemma in excluded { words[lemma] = nil }
for (lemma, forms) in formsOf where words[lemma] != nil {
    words[lemma]!.forms = forms.sorted()
    words[lemma]!.occurrences = Array(Set(words[lemma]!.occurrences)).sorted()
}

// MARK: - Traduction

let es = Locale.Language(identifier: "es"), fr = Locale.Language(identifier: "fr")
guard await LanguageAvailability().status(from: es, to: fr) == .installed else {
    print("Traduction espagnol → français non installée : Réglages Système › Général › "
          + "Langue et région › Langues de traduction.")
    exit(1)
}
let session = TranslationSession(installedSource: es, target: fr)
let toTranslate = words.keys.filter { corrections.translations[$0] == nil }.sorted()
let responses = try await session.translations(from: toTranslate.map {
    TranslationSession.Request(sourceText: $0, clientIdentifier: $0)
})
for r in responses {
    guard let lemma = r.clientIdentifier else { continue }
    // « Animal de compagnie. » → « animal de compagnie » : un sens, pas une phrase.
    var t = r.targetText.trimmingCharacters(in: .whitespaces)
    if t.hasSuffix(".") { t.removeLast() }
    if let first = t.first { t = first.lowercased() + t.dropFirst() }
    words[lemma]?.translation = t.isEmpty ? nil : t
}
for (lemma, t) in corrections.translations { words[canonical(lemma) ?? lemma]?.translation = t }

// MARK: - Renommages

// Ceux d'avant, plus ceux de cette génération ; une ancienne forme revenue dans le
// vocabulaire n'est plus un renommage, et les chaînes a → b → c se raccourcissent.
var renamed = previous?.renamed ?? [:]
for (raw, corrected) in rawToCorrected where words[raw] == nil { renamed[raw] = corrected }
if let previous {
    for old in previous.words.map(\.lemma) where words[old] == nil && renamed[old] == nil {
        print("attention : « \(old) » a disparu sans renommage, ses cartes resteraient orphelines")
    }
}
for key in renamed.keys {
    var target = renamed[key]!, seen: Set<String> = [key]
    while let next = renamed[target], !seen.contains(target) { seen.insert(target); target = next }
    renamed[key] = target
}
renamed = renamed.filter { words[$0.key] == nil && $0.key != $0.value }

// MARK: - Sortie

let sorted = words.values.sorted { ($0.firstLesson, -$0.count, $0.lemma) < ($1.firstLesson, -$1.count, $1.lemma) }
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(Output(version: 1, words: sorted, renamed: renamed)).write(to: outURL)

let perLesson = Dictionary(grouping: sorted, by: \.firstLesson).values.map(\.count).sorted()
print("""
    \(lessons.count) leçons, \(tokens) mots lus (mots-outils et noms propres écartés)
    \(sorted.count) mots à apprendre, \(perLesson[perLesson.count / 2]) nouveaux par leçon (médiane)
    corrections : \(correctedTokens) occurrences de forme, \(excluded.count) mots écartés, \
    \(corrections.translations.count) traductions ; \(renamed.count) renommages gardés
    sans traduction : \(sorted.filter { $0.translation == nil }.count)
    → \(outURL.path)
    """)
