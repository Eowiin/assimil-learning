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
//     "excluded":     [ "fa", "pues" ],           mots qui ne feront pas de carte
//     "expressions":  { "qué tal": [],             une expression = une carte
//                       "tener ganas de": ["tengo ganas de"] }
//   }
//
// Une expression est reconnue avant le découpage en mots : par sa forme écrite, par
// ses variantes, ou par la suite des formes de base (« tienes ganas de » → tener gana
// de). Les mots qu'elle couvre ne comptent pas comme mots seuls à cet endroit : dans
// « ¿Qué tal? », « tal » n'est pas « tel ». Le résumé liste les expressions jamais
// trouvées.
//
// La phrase d'exemple de chaque mot (sa première occurrence) est aussi traduite quand
// le livre n'en donne pas le français : c'est elle qui donne le sens.
//
// Une forme de base corrigée garde la trace de l'ancienne (`renamed`) : une carte déjà
// posée sur l'ancienne se déplace dans l'app au lieu de rester orpheline. Les
// renommages des générations précédentes sont conservés.

import Foundation
import NaturalLanguage
import Translation

struct Sentence: Decodable { let n: Int; let es: String; let fr: String? }
struct Lesson: Decodable { let number: Int; let sentences: [Sentence]; let exercise: [Sentence]? }

struct Corrections: Decodable {
    var forms: [String: String] = [:]
    var lemmas: [String: String] = [:]
    var translations: [String: String] = [:]
    var excluded: [String] = []
    var expressions: [String: [String]] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forms = try c.decodeIfPresent([String: String].self, forKey: .forms) ?? [:]
        lemmas = try c.decodeIfPresent([String: String].self, forKey: .lemmas) ?? [:]
        translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
        expressions = try c.decodeIfPresent([String: [String]].self, forKey: .expressions) ?? [:]
    }
    private enum CodingKeys: String, CodingKey { case forms, lemmas, translations, excluded, expressions }
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
    /// Traduction automatique des phrases d'exemple sans français du livre,
    /// par chemin de phrase (« L012:S04 »).
    var sentences: [String: String]? = nil
}

/// La même règle que `VocabItem.canonical` dans l'app : minuscules, Unicode composé,
/// sans ponctuation autour, sans « : » ni « # », les mots d'une expression séparés
/// par une seule espace.
func canonical(_ word: String) -> String? {
    let s = word.lowercased().precomposedStringWithCanonicalMapping
        .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !s.isEmpty, !s.contains(where: { $0 == ":" || $0 == "#" }) else { return nil }
    return s
}

func path(lesson: Int, isExercise: Bool, n: Int) -> String {
    String(format: "L%03d:%@%02d", lesson, isExercise ? "T" : "S", n)
}

/// Les mots d'un texte, avec leur forme de base, dans l'ordre : de quoi reconnaître
/// une expression par sa forme écrite ou par ses formes de base.
struct Token { let range: Range<String.Index>; let form: String; let lemma: String }

func tokens(_ text: String, tagger: NLTagger) -> [Token] {
    tagger.string = text
    tagger.setLanguage(.spanish, range: text.startIndex..<text.endIndex)
    var result: [Token] = []
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                         options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
        guard let form = canonical(String(text[range])), form.contains(where: \.isLetter) else { return true }
        result.append(Token(range: range, form: form, lemma: tag.flatMap { canonical($0.rawValue) } ?? form))
        return true
    }
    return result
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

// MARK: - Expressions

let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])

/// Une expression et les suites qui la reconnaissent : formes écrites (la clé et ses
/// variantes) et formes de base de la clé.
struct Expression { let key: String; let formSequences: [[String]]; let lemmaSequence: [String] }

let expressions: [Expression] = corrections.expressions.compactMap { key, variants in
    guard let key = canonical(key) else { return nil }
    let forms = ([key] + variants).compactMap(canonical).map { tokens($0, tagger: tagger).map(\.form) }
    return Expression(key: key, formSequences: forms, lemmaSequence: tokens(key, tagger: tagger).map(\.lemma))
}
// Les plus longues d'abord : « o sea que » avant « o sea ».
.sorted { ($0.formSequences.map(\.count).max() ?? 0) > ($1.formSequences.map(\.count).max() ?? 0) }

/// Les expressions d'une phrase : la clé de chacune, et les mots qu'elles couvrent.
func findExpressions(in toks: [Token]) -> (keys: [String], covered: Set<String.Index>) {
    var keys: [String] = [], covered = Set<String.Index>()
    var i = 0
    outer: while i < toks.count {
        for e in expressions {
            for seq in e.formSequences + [e.lemmaSequence] where !seq.isEmpty && i + seq.count <= toks.count {
                let window = toks[i..<(i + seq.count)]
                if window.map(\.form) == seq || window.map(\.lemma) == seq {
                    keys.append(e.key)
                    window.forEach { covered.insert($0.range.lowerBound) }
                    i += seq.count
                    continue outer
                }
            }
        }
        i += 1
    }
    return (keys, covered)
}

// MARK: - Mots et formes de base

var words: [String: Word] = [:]
var formsOf: [String: Set<String>] = [:]
var rawToCorrected: [String: String] = [:]
var tokenCount = 0, correctedTokens = 0
var expressionHits: [String: Int] = [:]
var bookFR: [String: String] = [:]

for lesson in lessons {
    let sentences = lesson.sentences.map { ($0, false) } + (lesson.exercise ?? []).map { ($0, true) }
    for (s, isExercise) in sentences {
        let text = s.es
        let occurrence = Occurrence(lesson: lesson.number, isExercise: isExercise, n: s.n)
        if let fr = s.fr, !fr.isEmpty { bookFR[path(lesson: lesson.number, isExercise: isExercise, n: s.n)] = fr }

        // Les expressions d'abord : une carte chacune, et leurs mots mis de côté.
        let found = findExpressions(in: tokens(text, tagger: tagger))
        for key in found.keys {
            expressionHits[key, default: 0] += 1
            if var w = words[key] {
                w.count += 1
                if w.occurrences.last != occurrence { w.occurrences.append(occurrence) }
                words[key] = w
            } else {
                words[key] = Word(lemma: key, forms: [], translation: nil, firstLesson: lesson.number,
                                  count: 1, occurrences: [occurrence])
            }
            formsOf[key, default: []].insert(key)
        }

        tagger.string = text
        tagger.setLanguage(.spanish, range: text.startIndex..<text.endIndex)
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            guard let form = canonical(String(text[range])), form.contains(where: \.isLetter) else { return true }
            if found.covered.contains(range.lowerBound) { return true }
            if functionClasses.contains(tag ?? .otherWord) { return true }
            // Une majuscule hors début de phrase : un prénom, une ville. « ¡Hola » ou
            // « ¿Eres » ouvrent la phrase : seules des lettres avant comptent.
            let startsSentence = !text[..<range.lowerBound].contains(where: \.isLetter)
            if !startsSentence, text[range].first?.isUppercase == true { return true }

            tokenCount += 1
            let raw = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
                .flatMap { canonical($0.rawValue) } ?? form
            var lemma = corrections.forms[form] ?? raw
            lemma = corrections.lemmas[lemma] ?? lemma
            if lemma != raw { rawToCorrected[raw] = lemma; correctedTokens += 1 }

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

// La phrase d'exemple (première occurrence) de chaque mot, quand le livre n'en donne
// pas le français.
var esByPath: [String: String] = [:]
for lesson in lessons {
    for s in lesson.sentences { esByPath[path(lesson: lesson.number, isExercise: false, n: s.n)] = s.es }
    for s in lesson.exercise ?? [] { esByPath[path(lesson: lesson.number, isExercise: true, n: s.n)] = s.es }
}
let examplePaths = Set(words.values.compactMap { $0.occurrences.first }
    .map { path(lesson: $0.lesson, isExercise: $0.isExercise, n: $0.n) })
    .filter { bookFR[$0] == nil && esByPath[$0] != nil }
var sentenceFR: [String: String] = [:]
for r in try await session.translations(from: examplePaths.sorted().map {
    TranslationSession.Request(sourceText: esByPath[$0]!, clientIdentifier: $0)
}) {
    if let id = r.clientIdentifier { sentenceFR[id] = r.targetText }
}

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
try encoder.encode(Output(version: 1, words: sorted, renamed: renamed, sentences: sentenceFR)).write(to: outURL)

let perLesson = Dictionary(grouping: sorted, by: \.firstLesson).values.map(\.count).sorted()
print("""
    \(lessons.count) leçons, \(tokenCount) mots lus (mots-outils et noms propres écartés)
    \(expressionHits.count) expressions sur \(expressions.count) trouvées, \(expressionHits.values.reduce(0, +)) fois\
    \(expressions.map(\.key).filter { expressionHits[$0] == nil }.sorted().map { "\n  jamais trouvée : « \($0) »" }.joined())
    \(sentenceFR.count) phrases d'exemple traduites
    \(sorted.count) mots à apprendre, \(perLesson[perLesson.count / 2]) nouveaux par leçon (médiane)
    corrections : \(correctedTokens) occurrences de forme, \(excluded.count) mots écartés, \
    \(corrections.translations.count) traductions ; \(renamed.count) renommages gardés
    sans traduction : \(sorted.filter { $0.translation == nil }.count)
    → \(outURL.path)
    """)
