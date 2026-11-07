// Mesure, avant de construire le module de vocabulaire, ce que valent les outils
// d'Apple sur le texte des leçons (docs/cadrage-app.md, « Les trois inconnues ») :
//
//   1. trouver les mots et leur forme de base (NaturalLanguage, schéma lemma) ;
//   2. écarter les mots-outils (classe lexicale) ;
//   3. traduire un mot isolé en français (Translation, sur l'appareil).
//
// Usage :
//   swift tools/vocabulaire/mesure.swift <dossier des textes> <dossier de sortie> [leçons]
//   swift tools/vocabulaire/mesure.swift Resources/text "$TMPDIR/vocab" 1-5
//
// Le texte Assimil est hors dépôt : la sortie (vocab.csv, resume.txt) aussi. Sans
// leçons précisées, toutes les leçons trouvées sont lues — utile pour compter le
// vocabulaire total et le rythme d'arrivée des mots.

import Foundation
import NaturalLanguage
import Translation

struct Sentence: Decodable { let n: Int; let es: String; let fr: String? }
struct Lesson: Decodable { let number: Int; let sentences: [Sentence]; let exercise: [Sentence]? }

/// Une forme de base, la première fois qu'elle apparaît.
struct Entry {
    let lemma: String
    let lexicalClass: String
    var forms: Set<String>
    var count: Int
    let firstLesson: Int
    let example: String
    let exampleFR: String?
    var lemmaFound: Bool
}

/// Classes écartées : elles relient les mots, elles ne s'apprennent pas en cartes.
let functionClasses: Set<NLTag> = [.determiner, .preposition, .conjunction, .pronoun,
                                   .particle, .classifier, .idiom, .otherWord]

func lessonNumbers(_ arg: String?) -> ClosedRange<Int>? {
    guard let arg else { return nil }
    let parts = arg.split(separator: "-").compactMap { Int($0) }
    return parts.count == 2 ? parts[0]...parts[1] : parts.first.map { $0...$0 }
}

@main
struct Mesure {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage : mesure.swift <dossier des textes> <dossier de sortie> [1-5]")
            exit(1)
        }
        let textDir = URL(fileURLWithPath: args[1])
        let outDir = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let range = lessonNumbers(args.count > 3 ? args[3] : nil) ?? 1...999

        var lessons: [Lesson] = []
        for n in range {
            let url = textDir.appendingPathComponent(String(format: "L%03d.json", n))
            guard let data = try? Data(contentsOf: url) else { continue }
            lessons.append(try JSONDecoder().decode(Lesson.self, from: data))
        }
        guard !lessons.isEmpty else { print("aucune leçon lue dans \(textDir.path)"); exit(1) }

        // MARK: Mots et formes de base

        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        var entries: [String: Entry] = [:]
        var tokens = 0, tokensFunction = 0, tokensNoLemma = 0, tokensNames = 0
        var newPerLesson: [Int: Int] = [:]

        for lesson in lessons {
            for s in lesson.sentences + (lesson.exercise ?? []) {
                tagger.string = s.es
                tagger.setLanguage(.spanish, range: s.es.startIndex..<s.es.endIndex)
                tagger.enumerateTags(in: s.es.startIndex..<s.es.endIndex, unit: .word, scheme: .lexicalClass,
                                     options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
                    let form = String(s.es[range]).lowercased()
                    guard form.rangeOfCharacter(from: .letters) != nil else { return true }
                    tokens += 1
                    let cls = tag ?? .otherWord
                    if functionClasses.contains(cls) { tokensFunction += 1; return true }
                    // Une majuscule en milieu de phrase : un prénom, une ville. Pas une carte.
                    // « ¡Hola » ou « ¿Eres » ouvrent la phrase : seules des lettres avant comptent.
                    let startsSentence = !s.es[..<range.lowerBound].contains(where: \.isLetter)
                    if !startsSentence, s.es[range].first?.isUppercase == true {
                        tokensNames += 1; return true
                    }
                    let lemmaTag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
                    let lemma = lemmaTag?.rawValue.lowercased()
                    if lemma == nil { tokensNoLemma += 1 }
                    let key = lemma ?? form
                    if var e = entries[key] {
                        e.forms.insert(form); e.count += 1
                        entries[key] = e
                    } else {
                        entries[key] = Entry(lemma: key, lexicalClass: cls.rawValue, forms: [form], count: 1,
                                             firstLesson: lesson.number, example: s.es, exampleFR: s.fr,
                                             lemmaFound: lemma != nil)
                        newPerLesson[lesson.number, default: 0] += 1
                    }
                    return true
                }
            }
        }

        // MARK: Traduction d'un mot isolé

        let es = Locale.Language(identifier: "es"), fr = Locale.Language(identifier: "fr")
        let status = await LanguageAvailability().status(from: es, to: fr)
        var translations: [String: String] = [:]
        if status == .installed {
            let session = TranslationSession(installedSource: es, target: fr)
            let requests = entries.keys.sorted().map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
            for response in try await session.translations(from: requests) {
                if let id = response.clientIdentifier { translations[id] = response.targetText }
            }
        }

        // MARK: Sortie

        func csv(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var lines = ["lemme;classe;occurrences;formes;première leçon;forme de base trouvée;traduction;exemple;exemple FR"]
        for e in entries.values.sorted(by: { ($0.firstLesson, -$0.count, $0.lemma) < ($1.firstLesson, -$1.count, $1.lemma) }) {
            lines.append([csv(e.lemma), e.lexicalClass, String(e.count), csv(e.forms.sorted().joined(separator: " ")),
                          String(e.firstLesson), e.lemmaFound ? "oui" : "non", csv(translations[e.lemma] ?? ""),
                          csv(e.example), csv(e.exampleFR ?? "")].joined(separator: ";"))
        }
        try lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("vocab.csv"), atomically: true, encoding: .utf8)

        let perLesson = newPerLesson.values.sorted()
        let median = perLesson.isEmpty ? 0 : perLesson[perLesson.count / 2]
        let byClass = Dictionary(grouping: entries.values, by: \.lexicalClass).mapValues(\.count)
            .sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let summary = """
        Leçons lues : \(lessons.count) (\(lessons.first!.number) à \(lessons.last!.number))
        Mots lus : \(tokens)
          mots-outils écartés : \(tokensFunction) (\(tokens > 0 ? tokensFunction * 100 / tokens : 0) %)
          noms propres écartés : \(tokensNames)
          sans forme de base : \(tokensNoLemma)
        Formes de base retenues (= mots à apprendre) : \(entries.count)
          par classe : \(byClass)
          formes de base non trouvées (le mot tel quel) : \(entries.values.filter { !$0.lemmaFound }.count)
        Nouveaux mots par leçon : médiane \(median), min \(perLesson.first ?? 0), max \(perLesson.last ?? 0)
        Traduction es → fr : \(status == .installed ? "\(translations.count) mots traduits" : "non installée sur ce Mac (\(status))")
        """
        try summary.write(to: outDir.appendingPathComponent("resume.txt"), atomically: true, encoding: .utf8)
        print(summary)
        print("\nDétail : \(outDir.appendingPathComponent("vocab.csv").path)")
    }
}
