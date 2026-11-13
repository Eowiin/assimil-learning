import Foundation

// MARK: - Ce que rend le serveur

/// Un son attendu, jugé par le serveur (`server/app/main.py`, `Phone`).
struct JudgedPhone: Decodable, Equatable, Sendable {
    /// Le son attendu, en symbole phonétique (`θ`, `x`, `ɾ`…).
    let expected: String
    /// Ce qui a été entendu à la place, pour une faute ou un indice. `∅` : rien.
    let heard: String?
    let fault: Bool
    /// Qui l'a repéré : `gop`, `r` ou `zipa`.
    let reason: String?
    /// Un simple indice (le r roulé dit battu, que beaucoup de natifs font). Il ne
    /// rend pas le mot fautif.
    let hint: Bool
    /// Un conseil en français, pour une faute de francophone connue.
    let tip: String?
    /// Nul pour un son non noté (mot étranger, sigle).
    let score: Double?
    let threshold: Double?
    /// La place du son dans la prise, en secondes.
    let start: Double?
    let end: Double?
}

/// Un mot jugé. Le serveur l'écrit en minuscules, sans ponctuation, et les nombres
/// en lettres : il ne s'écrit pas forcément comme dans la phrase affichée.
struct JudgedWord: Decodable, Equatable, Sendable {
    let text: String
    let fault: Bool
    let phonemes: [JudgedPhone]

    /// La place du mot dans la prise, pour le réécouter seul. Nil si le serveur
    /// n'a placé aucun de ses sons.
    var timeRange: ClosedRange<Double>? {
        guard let start = phonemes.compactMap(\.start).min(),
              let end = phonemes.compactMap(\.end).max(), end > start
        else { return nil }
        return start...end
    }

    var hasHint: Bool { phonemes.contains(where: \.hint) }
}

/// Le jugement d'une phrase (`POST /pronunciation`).
struct PronunciationResult: Decodable, Equatable, Sendable {
    let words: [JudgedWord]
    /// Les sons reconnus, sans la phrase attendue.
    let heard: String
    /// Le temps de l'analyse sur le PC.
    let seconds: Double

    var hasFault: Bool { words.contains(where: \.fault) }
}

/// Ce que l'écran attend du serveur. `PronunciationClient` le joint par Tailscale ;
/// les tests passent un faux.
protocol PronunciationService: Sendable {
    /// `audio` : la prise, en AAC. `text` : la phrase attendue, telle qu'affichée.
    func judge(audio: Data, text: String) async throws -> PronunciationResult
}

// MARK: - Le client

struct PronunciationClient: PronunciationService {
    let baseURL: URL
    var session: URLSession = .shared

    /// L'analyse prend 0,2 s sur le PC. Le reste est du réseau.
    static let timeout: TimeInterval = 30

    func judge(audio: Data, text: String) async throws -> PronunciationResult {
        let form = Self.form(audio: audio, text: text)
        return try await HomeServer.post("pronunciation", base: baseURL, body: form.body,
                                         contentType: form.contentType, timeout: Self.timeout,
                                         session: session, as: PronunciationResult.self)
    }

    static func form(audio: Data, text: String,
                     boundary: String = "assimil-\(UUID().uuidString)") -> (body: Data, contentType: String) {
        var form = MultipartForm(boundary: boundary)
        form.field("text", text)
        form.audio("audio", filename: "phrase.m4a", audio)
        return form.finished()
    }
}

// MARK: - Les mots jugés, rattachés à la phrase affichée

/// Un mot de la phrase affichée, et son jugement s'il a pu y être rattaché.
struct DisplayedWord: Identifiable, Equatable {
    let id: Int
    let text: String
    let judged: JudgedWord?

    var isFault: Bool { judged?.fault == true }
    var hasHint: Bool { judged?.hasHint == true && !isFault }
}

enum PronunciationMatch {

    /// Rattache chaque mot jugé à son mot affiché. Les deux sont repliés comme
    /// `SpanishMatch` (minuscules, sans accents, sans ponctuation, sans espaces), puis
    /// comparés lettre à lettre.
    ///
    /// Un mot jugé n'est rattaché que si **toutes** ses lettres retombent dans **un
    /// seul** mot affiché, et en couvrent au moins la moitié. Sinon — « 3 » affiché,
    /// « tres » jugé — il reste sans place : mieux vaut ne rien souligner que
    /// souligner le mauvais mot.
    static func attach(_ judged: [JudgedWord], to sentence: String) -> [DisplayedWord] {
        let ranges = SpanishMatch.words(in: sentence)
        let display = SpanishMatch.fold(sentence)
        // Le mot affiché de chaque lettre repliée.
        let displayOwner = display.origin.map { index in ranges.firstIndex { $0.contains(index) } ?? -1 }
        var displayLength = [Int: Int]()
        for owner in displayOwner { displayLength[owner, default: 0] += 1 }

        var judgedLetters: [Character] = []
        var judgedOwner: [Int] = []
        for (i, word) in judged.enumerated() {
            let letters = SpanishMatch.fold(word.text).folded
            judgedLetters += letters
            judgedOwner += Array(repeating: i, count: letters.count)
        }

        // Les lettres communes aux deux, dans l'ordre : ce que le diff ne touche pas.
        let diff = judgedLetters.difference(from: display.folded)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var landing = [Int: [Int]]()  // mot jugé → mots affichés où tombent ses lettres
        var d = 0, j = 0
        while d < display.folded.count, j < judgedLetters.count {
            if removed.contains(d) { d += 1; continue }
            if inserted.contains(j) { j += 1; continue }
            landing[judgedOwner[j], default: []].append(displayOwner[d])
            d += 1; j += 1
        }

        var claimed = [Int: [JudgedWord]]()
        for (i, word) in judged.enumerated() {
            let total = judgedOwner.filter { $0 == i }.count
            guard total > 0, let targets = landing[i], targets.count == total,
                  let target = targets.first, target >= 0, targets.allSatisfy({ $0 == target }),
                  total * 2 >= displayLength[target, default: 0]
            else { continue }
            claimed[target, default: []].append(word)
        }

        return ranges.enumerated().map { index, range in
            let words = claimed[index] ?? []
            // Deux mots jugés dans un même mot affiché : un seul, aux sons mis bout à bout.
            let judged: JudgedWord? = switch words.count {
            case 0: nil
            case 1: words[0]
            default: JudgedWord(text: words.map(\.text).joined(separator: " "),
                                fault: words.contains(where: \.fault),
                                phonemes: words.flatMap(\.phonemes))
            }
            return DisplayedWord(id: index, text: String(sentence[range]), judged: judged)
        }
    }
}

// MARK: - Les sons, dits en clair

/// Les symboles phonétiques du serveur, traduits pour un francophone. Les sons des
/// fautes connues (θ, jota, r, b/v) ont une description ; les autres reprennent
/// `FRENCH_LABELS` du serveur (`app/prononciation/coach/phones.py`).
enum SpanishSounds {

    private static let labels: [String: String] = [
        // Les fautes de francophone que le serveur repère.
        "θ": "le th anglais (« think »)",
        "x": "la jota, raclée au fond de la gorge",
        "ɾ": "le r battu, un seul coup de langue",
        "r": "le r roulé",
        "b": "le b, lèvres qui se touchent à peine",
        "β": "le b, lèvres qui se touchent à peine",
        "s": "un s",
        "ʁ": "un r français, de gorge",
        "χ": "un r français, de gorge",
        "ʀ": "un r grasseyé",
        "v": "un v, dents sur la lèvre",
        // Le reste, d'après le serveur.
        "ɹ": "un r anglais", "h": "un h expiré", "ʝ": "le y espagnol", "ʎ": "le ll",
        "tʃ": "le ch espagnol (« tch »)", "ʃ": "un ch français", "ʒ": "un j français",
        "dʒ": "un dj", "ɲ": "le ñ (« gn »)", "ð": "le d doux", "ɣ": "le g doux",
        "d": "le d", "g": "le g", "z": "un z", "ə": "un e muet", "u": "le u (« ou »)",
        "y": "un u français", "j": "un i bref", "w": "un ou bref",
        "ɑ̃": "un « an » nasal", "ɔ̃": "un « on » nasal", "ɛ̃": "un « in » nasal",
        "œ̃": "un « un » nasal", "e": "le e (« é »)", "ɛ": "un è", "o": "le o",
        "ɔ": "un o ouvert",
    ]

    /// « le th anglais (« think ») ». Un symbole inconnu reste tel quel, entre crochets.
    static func label(_ symbol: String) -> String {
        labels[symbol] ?? "[\(symbol)]"
    }

    /// La phrase qui dit la faute : « Tu as dit un s. Il faut le th anglais (« think »). »
    static func correction(for phone: JudgedPhone) -> String {
        let expected = label(phone.expected)
        guard let heard = phone.heard, heard != phone.expected else {
            return "Ce son n'est pas encore \(expected)."
        }
        if heard == "∅" { return "Tu as sauté \(expected)." }
        if phone.hint {
            return "Indice : \(expected) est sorti comme \(label(heard)). Beaucoup de natifs le font."
        }
        return "Tu as dit \(label(heard)). Il faut \(expected)."
    }
}

#if DEBUG
/// Le serveur imaginaire des tests d'interface (`ASSIMIL_FAKE_SERVER`) : le premier
/// mot qui a un r est jugé dit avec un r français, les autres sont bons.
struct FakePronunciationService: PronunciationService {
    func judge(audio: Data, text: String) async throws -> PronunciationResult {
        var faulted = false
        let words = SpanishMatch.words(in: text).map { range -> JudgedWord in
            let word = String(SpanishMatch.fold(String(text[range])).folded)
            guard !faulted, word.contains("r") else {
                return JudgedWord(text: word, fault: false, phonemes: [])
            }
            faulted = true
            return JudgedWord(text: word, fault: true, phonemes: [
                JudgedPhone(expected: "ɾ", heard: "ʁ", fault: true, reason: "r", hint: false,
                            tip: "Le r se fait du bout de la langue, derrière les dents du haut, "
                                + "pas au fond de la gorge comme en français.",
                            score: nil, threshold: nil, start: 0.2, end: 0.3),
            ])
        }
        return PronunciationResult(words: words.filter { !$0.text.isEmpty }, heard: "", seconds: 0)
    }
}
#endif
