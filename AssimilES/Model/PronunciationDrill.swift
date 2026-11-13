import Foundation

/// Les sons qu'un francophone rate, et que le serveur repère (#44).
enum SpanishTarget: String, CaseIterable, Hashable, Sendable {
    /// `z`, `ce`, `ci` : le th anglais, souvent dit [s].
    case theta
    /// `j`, `ge`, `gi` : souvent dite comme un r français.
    case jota
    /// `r` et `rr` : souvent dits au fond de la gorge.
    case r
    /// `v` : un b en espagnol, souvent dit [v]. Le `b` écrit, lui, n'est jamais dit
    /// [v] par un francophone : il n'y a rien à y travailler.
    case v
}

/// Une phrase à lire, avec la voix du natif.
struct DrillSentence: Identifiable, Hashable {
    let lesson: Int
    let n: Int
    let text: String
    let clip: AudioClip
    let targets: Set<SpanishTarget>

    var id: String { "\(lesson)-\(n)" }
}

/// Le choix des phrases d'une séance de prononciation (`docs/module-prononciation.md`).
enum PronunciationDrill {

    /// Cinq phrases par séance (décision 1 du plan).
    static let size = 5
    /// Plus court, il y a peu à juger. Plus long, la prise devient une lecture, et
    /// l'erreur se perd.
    static let wordRange = 4...12

    /// Les sons à travailler dans une phrase, repérés à l'orthographe, sans le serveur.
    static func targets(in text: String) -> Set<SpanishTarget> {
        // Mot par mot, minuscules et sans accents : « cénit » vaut « cenit », et le
        // « c » final d'un mot ne se lie pas au « e » du suivant.
        let words = SpanishMatch.words(in: text).map { String(SpanishMatch.fold(String(text[$0])).folded) }
        var found = Set<SpanishTarget>()
        for word in words {
            if word.contains("z") || word.contains("ce") || word.contains("ci") { found.insert(.theta) }
            if word.contains("j") || word.contains("ge") || word.contains("gi") { found.insert(.jota) }
            if word.contains("r") { found.insert(.r) }
            if word.contains("v") { found.insert(.v) }
        }
        return found
    }

    /// Le nombre de mots à dire : un tiret de dialogue n'en est pas un.
    static func wordCount(_ text: String) -> Int {
        SpanishMatch.words(in: text).filter { !SpanishMatch.fold(String(text[$0])).folded.isEmpty }.count
    }

    /// Les phrases possibles : le dialogue des leçons vues, avec sa voix, de la bonne
    /// longueur, et avec au moins un son à travailler. Une leçon sans texte importé
    /// ne donne rien.
    static func candidates(lessons: Set<Int>, manifest: Manifest,
                           text: (Int) -> LessonText? = LessonTextStore.text(for:)) -> [DrillSentence] {
        var seen = Set<String>()
        var result: [DrillSentence] = []
        for number in lessons.sorted() {
            guard let lesson = manifest.lesson(number), let lessonText = text(number) else { continue }
            for sentence in lessonText.sentences {
                guard let clip = lesson.dialogue.first(where: { $0.n == sentence.n }),
                      wordRange.contains(wordCount(sentence.es))
                else { continue }
                let targets = targets(in: sentence.es)
                // Une même phrase dans deux leçons n'est proposée qu'une fois.
                let key = String(SpanishMatch.fold(sentence.es).folded)
                guard !targets.isEmpty, seen.insert(key).inserted else { continue }
                result.append(DrillSentence(lesson: number, n: sentence.n, text: sentence.es,
                                            clip: clip, targets: targets))
            }
        }
        return result
    }

    /// Les phrases d'une séance, au hasard, en couvrant d'abord chacun des sons, les
    /// plus rares en premier : le r est partout, le θ beaucoup moins. Moins de `size`
    /// candidates : toutes, mélangées.
    static func pick<G: RandomNumberGenerator>(from candidates: [DrillSentence], count: Int = size,
                                               using generator: inout G) -> [DrillSentence] {
        var pool = candidates.shuffled(using: &generator)
        var picked: [DrillSentence] = []
        let rarestFirst = SpanishTarget.allCases.shuffled(using: &generator).enumerated()
            .sorted { a, b in
                let (ca, cb) = (candidates.count { $0.targets.contains(a.element) },
                                candidates.count { $0.targets.contains(b.element) })
                return ca != cb ? ca < cb : a.offset < b.offset
            }
            .map(\.element)
        for target in rarestFirst where picked.count < count {
            guard !picked.contains(where: { $0.targets.contains(target) }),
                  let index = pool.firstIndex(where: { $0.targets.contains(target) })
            else { continue }
            picked.append(pool.remove(at: index))
        }
        picked += pool.prefix(count - picked.count)
        return picked.shuffled(using: &generator)
    }

    static func pick(from candidates: [DrillSentence], count: Int = size) -> [DrillSentence] {
        var generator = SystemRandomNumberGenerator()
        return pick(from: candidates, count: count, using: &generator)
    }

    /// Les leçons d'où tirer les phrases : celles du vocabulaire (validées avant
    /// aujourd'hui, et celles d'avant le point de départ). Au tout début du parcours,
    /// il n'y en a aucune : on prend la première.
    static func lessons(available: Set<Int>) -> Set<Int> {
        available.isEmpty ? [1] : available
    }
}
