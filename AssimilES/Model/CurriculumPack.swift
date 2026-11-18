import Foundation

/// Le référentiel du moteur adaptatif, pour une langue : `curriculum/<langue>/` dans le
/// bundle. Du contenu seulement, jamais l'état de l'apprenant (qui vit dans SwiftData,
/// sous des clés préfixées par la langue : « es:obj_014 », « es:hablar »).
///
/// - `objectives.json` : les 125 micro-objectifs, de A0 à C2, dans l'ordre du parcours ;
/// - `microlessons.json` : la micro-leçon de chaque objectif (5 lignes au plus), écrite
///   une fois et relue ;
/// - `placement_challenges.json` : un défi de placement par objectif ;
/// - `lexicon.json` : les 5 000 lemmes les plus fréquents, avec l'API castillane
///   (`server/scripts/build_lexicon.py`) ;
/// - `pseudowords.json` : des non-mots pour le test de vocabulaire ;
/// - `phonemes.json` : les sons et règles de prosodie, avec leur priorité pour un francophone.
///
/// Les noms de champs suivent les fichiers, écrits en français pour une part : le serveur
/// les lit aussi, tels quels.
struct CurriculumPack: Equatable {
    let language: String
    let objectives: [Objective]
    let microlessons: [String: MicroLesson]
    let challenges: [PlacementChallenge]
    let lexicon: [Lexeme]
    let pseudowords: [String]
    let phonemes: [Phoneme]

    struct Objective: Decodable, Equatable, Identifiable {
        let id: String
        let level: String
        let title: String
        let rule: String
        let aiPrompt: String
        let validation: String

        private enum CodingKeys: String, CodingKey {
            case id, level = "niveau", title = "titre", rule = "regle", aiPrompt = "prompt_ia", validation
        }
    }

    struct MicroLesson: Decodable, Equatable {
        struct Example: Decodable, Equatable {
            let es: String
            let fr: String
        }
        let objective: String
        let lines: [String]
        let examples: [Example]
    }

    struct PlacementChallenge: Decodable, Equatable, Identifiable {
        enum Kind: String, Decodable {
            case complete, translate, rewrite
        }
        let id: String
        let objective: String
        let level: String
        let type: Kind
        let instruction: String
        let prompt: String
        /// Les réponses qui montrent l'objectif.
        let expected: [String]
        /// Des réponses justes qui contournent l'objectif (« debe de estar » au lieu du
        /// futur de probabilité) : verdict intermédiaire, on repose un défi sans
        /// compter de lacune.
        let alsoCorrect: [String]
        let check: String

        /// Les trois verdicts du correcteur (`/placement/evaluate`).
        enum Verdict: String, Codable {
            case shown
            case correctNotShown = "correct_not_shown"
            case wrong
        }

        private enum CodingKeys: String, CodingKey {
            case id, objective, level, type, instruction, prompt, expected, alsoCorrect = "also_correct", check
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            objective = try c.decode(String.self, forKey: .objective)
            level = try c.decode(String.self, forKey: .level)
            type = try c.decode(Kind.self, forKey: .type)
            instruction = try c.decode(String.self, forKey: .instruction)
            prompt = try c.decode(String.self, forKey: .prompt)
            expected = try c.decode([String].self, forKey: .expected)
            alsoCorrect = try c.decodeIfPresent([String].self, forKey: .alsoCorrect) ?? []
            check = try c.decode(String.self, forKey: .check)
        }
    }

    struct Lexeme: Decodable, Equatable {
        let rank: Int
        let lemma: String
        let pos: String
        let ipa: String
        let level: String
    }

    struct Phoneme: Decodable, Equatable, Identifiable {
        let id: String
        let ipa: String
        let type: String
        let spelling: String
        let example: String
        let priority: String
        let note: String

        private enum CodingKeys: String, CodingKey {
            case id, ipa, type, spelling = "graphie", example = "exemple", priority = "priorite_fr", note
        }
    }

    /// Les niveaux du CECRL dans l'ordre, A0 compris (les tout premiers objectifs).
    static let levels = ["A0", "A1", "A2", "B1", "B2", "C1", "C2"]

    func objective(_ id: String) -> Objective? { objectives.first { $0.id == id } }

    /// Le rang de chaque lemme, pour la reprise du vocabulaire d'Assimil.
    var ranks: [String: Int] {
        Dictionary(lexicon.map { ($0.lemma, $0.rank) }, uniquingKeysWith: min)
    }
}

// MARK: - Lecture

extension CurriculumPack {
    enum LoadError: Error, Equatable {
        case missing(String)
        case unreadable(String, String)
        case wrongLanguage(String)
        case inconsistent(String)
    }

    /// Le paquet du bundle, ou nil s'il manque ou ne se lit pas : comme pour Assimil,
    /// un paquet absent est un état normal, pas une raison de planter.
    static func bundled(language: String = "es", bundle: Bundle = .main) -> CurriculumPack? {
        guard let root = bundle.resourceURL?.appendingPathComponent("curriculum/\(language)", isDirectory: true)
        else { return nil }
        return try? load(from: root, language: language)
    }

    static func load(from directory: URL, language: String) throws -> CurriculumPack {
        let objectives: [Objective] = try read("objectives.json", key: "objectives", in: directory, language: language)
        let lessons: [MicroLesson] = try read("microlessons.json", key: "microlessons", in: directory, language: language)
        let challenges: [PlacementChallenge] = try read("placement_challenges.json", key: "challenges",
                                                        in: directory, language: language)
        let lexicon: [Lexeme] = try read("lexicon.json", key: "lemmas", in: directory, language: language)
        let pseudowords: [String] = try read("pseudowords.json", key: "pseudowords", in: directory, language: language)
        let phonemes: [Phoneme] = try read("phonemes.json", key: "phonemes", in: directory, language: language)

        let pack = CurriculumPack(
            language: language, objectives: objectives,
            microlessons: Dictionary(lessons.map { ($0.objective, $0) }, uniquingKeysWith: { first, _ in first }),
            challenges: challenges, lexicon: lexicon, pseudowords: pseudowords, phonemes: phonemes)
        try pack.validate()
        return pack
    }

    /// Ce que l'app suppose ailleurs : chaque leçon et chaque défi désignent un
    /// objectif qui existe, les rangs se suivent.
    func validate() throws {
        let ids = Set(objectives.map(\.id))
        guard ids.count == objectives.count else { throw LoadError.inconsistent("objectifs en double") }
        if let orphan = microlessons.keys.first(where: { !ids.contains($0) }) {
            throw LoadError.inconsistent("micro-leçon sans objectif : \(orphan)")
        }
        if let orphan = challenges.first(where: { !ids.contains($0.objective) }) {
            throw LoadError.inconsistent("défi sans objectif : \(orphan.id)")
        }
        guard lexicon.enumerated().allSatisfy({ $0.offset + 1 == $0.element.rank }) else {
            throw LoadError.inconsistent("rangs du lexique")
        }
    }

    private struct Envelope<Item: Decodable>: Decodable {
        let language: String
        let items: [Item]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            language = try container.decode(String.self, forKey: AnyKey("language"))
            let key = decoder.userInfo[.envelopeKey] as? String ?? "items"
            items = try container.decode([Item].self, forKey: AnyKey(key))
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static func read<Item: Decodable>(_ file: String, key: String, in directory: URL,
                                              language: String) throws -> [Item] {
        let url = directory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missing(file) }
        let decoder = JSONDecoder()
        decoder.userInfo[.envelopeKey] = key
        let envelope: Envelope<Item>
        do {
            envelope = try decoder.decode(Envelope<Item>.self, from: data)
        } catch {
            throw LoadError.unreadable(file, String(describing: error))
        }
        guard envelope.language == language else { throw LoadError.wrongLanguage(file) }
        return envelope.items
    }
}

/// Le paquet espagnol du bundle, lu une fois : l'accueil le consulte à chaque
/// affichage, et le lexique pèse 5 000 lignes.
@MainActor
enum CurriculumStore {
    private static var cache: CurriculumPack??

    static var spanish: CurriculumPack? {
        if let cache { return cache }
        let pack = CurriculumPack.bundled(language: "es")
        cache = .some(pack)
        return pack
    }
}

private extension CodingUserInfoKey {
    static let envelopeKey = CodingUserInfoKey(rawValue: "envelopeKey")!
}
